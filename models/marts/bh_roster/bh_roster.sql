{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- FL Behavioral Health Roster: union of address-based + billing-NPI-based (B0 logic).
-- See docs/B0_ROSTER_AND_ORG_STRUCTURE_PLAN.md. Enriched with taxonomy, PML, DOGE, explanations.

with bldg_density as (
  select
    substr(regexp_replace(provider_business_practice_location_address_postal_code, r'[^0-9]', ''), 1, 9) as zip9,
    count(distinct npi) as bldg_org_count
  from {{ source('nppes_public', 'npi_raw') }}
  where entity_type_code = 2
    and (
      provider_business_practice_location_address_state_name = '{{ var("state_code", "FL") }}'
      or provider_license_number_state_code_1 = '{{ var("state_code", "FL") }}'
    )
  group by 1
),

bh_orgs as (
  select
    cast(n.npi as string) as org_npi,
    coalesce(
      n.provider_organization_name_legal_business_name,
      p.provider_name
    ) as org_name,
    trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) as org_taxonomy_code,
    nucc.taxonomy_classification as org_taxonomy_classification,
    w.bh_grouping as org_bh_grouping,
    coalesce(
      n.provider_first_line_business_practice_location_address,
      p.address_line_1
    ) as org_address_line_1,
    coalesce(n.provider_business_practice_location_address_city_name, p.city) as org_city,
    coalesce(n.provider_business_practice_location_address_state_name, p.state) as org_state,
    coalesce(n.provider_business_practice_location_address_postal_code, p.zip) as org_zip,
    substr(regexp_replace(coalesce(
      n.provider_business_practice_location_address_postal_code,
      concat(coalesce(p.zip, ''), coalesce(p.zip_plus_4, ''))
    ), r'[^0-9]', ''), 1, 9) as org_zip9,
    regexp_replace(lower(coalesce(
      n.provider_first_line_business_practice_location_address,
      p.address_line_1
    )), r'[^a-z0-9]', '') as addr_clean_full
  from {{ source('nppes_public', 'npi_raw') }} n
  left join {{ source('landing_medicaid_npi', 'stg_pml') }} p
    on cast(n.npi as string) = cast(p.npi as string)
  left join {{ ref('nucc_lookup') }} nucc
    on trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) = nucc.taxonomy_code
  inner join {{ ref('stg_bh_taxonomy_whitelist') }} w
    on n.healthcare_provider_taxonomy_code_1 = w.code
  where n.entity_type_code = 2
    and (
      n.provider_business_practice_location_address_state_name = '{{ var("state_code", "FL") }}'
      or n.provider_license_number_state_code_1 = '{{ var("state_code", "FL") }}'
    )
),

-- DOGE: last 3 years (Feb 2022 onward) at pair level. Use stg_doge (canonical DOGE source).
doge_monthly_pair as (
  select
    cast(billing_npi as string) as billing_npi,
    cast(servicing_npi as string) as servicing_npi,
    substr(safe_cast(period_month as string), 1, 6) as claim_month,
    sum(coalesce(beneficiary_count, 0)) as beneficiaries,
    sum(coalesce(claim_count, 0)) as claims,
    sum(coalesce(total_paid, 0)) as paid
  from {{ ref('stg_doge') }}
  where substr(safe_cast(period_month as string), 1, 6) >= '202202'
  group by 1, 2, 3
),
doge_pair_3yr as (
  select
    billing_npi,
    servicing_npi,
    count(distinct claim_month) as months_with_claims_3yr,
    sum(claims) as total_claims_3yr,
    sum(paid) as total_spend_3yr,
    sum(beneficiaries) as total_beneficiaries_3yr,
    avg(beneficiaries) as avg_beneficiaries_per_month_3yr,
    max(claim_month) as last_active_month,
    sum(case when claim_month >= '202401' then claims else 0 end) as claims_2024_count
  from doge_monthly_pair
  group by 1, 2
),
-- Servicing NPI rollup (this NPI's totals across all billing orgs)
doge_npi_3yr as (
  select
    servicing_npi as npi,
    sum(claims) as npi_total_claims_3yr,
    sum(paid) as npi_total_spend_3yr,
    avg(beneficiaries) as npi_avg_beneficiaries_per_month_3yr
  from (
    select
      cast(servicing_npi as string) as servicing_npi,
      substr(safe_cast(period_month as string), 1, 6) as claim_month,
      sum(coalesce(beneficiary_count, 0)) as beneficiaries,
      sum(coalesce(claim_count, 0)) as claims,
      sum(coalesce(total_paid, 0)) as paid
    from {{ ref('stg_doge') }}
    where substr(safe_cast(period_month as string), 1, 6) >= '202202'
    group by 1, 2
  )
  group by 1
),

-- PML: one row per NPI (latest contract) for enrollment and address
pml_by_npi as (
  select
    cast(npi as string) as npi,
    provider_name as pml_provider_name,
    address_line_1 as pml_address_line_1,
    city as pml_city,
    state as pml_state,
    zip as pml_zip,
    zip_plus_4 as pml_zip_plus_4,
    contract_effective_date as pml_contract_effective_date,
    contract_end_date as pml_contract_end_date,
    substr(regexp_replace(concat(coalesce(zip, ''), coalesce(zip_plus_4, '')), r'[^0-9]', ''), 1, 9) as pml_zip9
  from {{ source('landing_medicaid_npi', 'stg_pml') }}
  where npi is not null
  qualify row_number() over (partition by cast(npi as string) order by contract_effective_date desc nulls last) = 1
),

-- BH orgs from any state (for billing-based: DOGE has national data; match by taxonomy)
bh_orgs_any_state as (
  select
    cast(n.npi as string) as org_npi,
    coalesce(n.provider_organization_name_legal_business_name, p.provider_name) as org_name,
    trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) as org_taxonomy_code,
    nucc.taxonomy_classification as org_taxonomy_classification,
    w.bh_grouping as org_bh_grouping,
    coalesce(n.provider_first_line_business_practice_location_address, p.address_line_1) as org_address_line_1,
    coalesce(n.provider_business_practice_location_address_city_name, p.city) as org_city,
    coalesce(n.provider_business_practice_location_address_state_name, p.state) as org_state,
    coalesce(n.provider_business_practice_location_address_postal_code, p.zip) as org_zip,
    substr(regexp_replace(coalesce(n.provider_business_practice_location_address_postal_code, concat(coalesce(p.zip, ''), coalesce(p.zip_plus_4, ''))), r'[^0-9]', ''), 1, 9) as org_zip9,
    regexp_replace(lower(coalesce(n.provider_first_line_business_practice_location_address, p.address_line_1)), r'[^a-z0-9]', '') as addr_clean_full
  from {{ source('nppes_public', 'npi_raw') }} n
  left join {{ source('landing_medicaid_npi', 'stg_pml') }} p on cast(n.npi as string) = cast(p.npi as string)
  left join {{ ref('nucc_lookup') }} nucc on trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) = nucc.taxonomy_code
  inner join {{ ref('stg_bh_taxonomy_whitelist') }} w on n.healthcare_provider_taxonomy_code_1 = w.code
  where n.entity_type_code = 2
),

-- B0 logic: address propensity (strong + partial). Strong: same practice/addr, same zip9. Partial: same zip5, same street, same city+state.
address_propensity_raw as (
  select
    o.org_npi,
    p.npi_str as servicing_npi,
    (o.addr_clean_full is not null and p.addr_clean_full is not null and o.addr_clean_full = p.addr_clean_full) as same_practice,
    (o.org_zip9 is not null and p.zip9 is not null and length(o.org_zip9) >= 5 and length(p.zip9) >= 5 and o.org_zip9 = p.zip9) as same_zip9,
    (o.org_zip9 is not null and p.zip9 is not null and length(o.org_zip9) >= 5 and length(p.zip9) >= 5
     and substr(o.org_zip9, 1, 5) = substr(p.zip9, 1, 5)) as same_zip5,
    (length(trim(o.org_address_line_1)) > 0 and length(trim(p.nppes_practice_line_1)) > 0
     and upper(trim(regexp_replace(coalesce(o.org_address_line_1, ''), r'\s+', ' '))) = upper(trim(regexp_replace(coalesce(p.nppes_practice_line_1, ''), r'\s+', ' ')))) as same_street,
    (length(trim(o.org_city)) > 0 and length(trim(p.nppes_practice_city)) > 0 and upper(trim(o.org_city)) = upper(trim(p.nppes_practice_city))
     and length(trim(o.org_state)) > 0 and length(trim(p.nppes_practice_state)) > 0 and upper(trim(o.org_state)) = upper(trim(p.nppes_practice_state))) as same_city_state
  from bh_orgs o
  inner join {{ ref('bh_provider_locations') }} p
    on (
      (o.org_zip9 is not null and p.zip9 is not null and length(o.org_zip9) >= 5 and length(p.zip9) >= 5 and substr(o.org_zip9, 1, 5) = substr(p.zip9, 1, 5))
      or (o.org_zip9 is null and p.zip9 is null and upper(trim(coalesce(o.org_city,''))) = upper(trim(coalesce(p.nppes_practice_city,''))) and upper(trim(coalesce(o.org_state,''))) = upper(trim(coalesce(p.nppes_practice_state,'')))
          and length(trim(o.org_city)) > 0 and length(trim(o.org_state)) > 0)
    )
  where o.org_npi != p.npi_str
),
address_based_pairs as (
  select
    org_npi,
    servicing_npi,
    'address' as source_type,
    case when same_practice or same_zip9 then 'strong' when same_zip5 or same_street or same_city_state then 'partial' else null end as address_match_type,
    trim(regexp_replace(concat(
      case when same_practice then 'same_practice,' else '' end,
      case when same_zip9 then 'same_zip9,' else '' end,
      case when same_zip5 then 'same_zip5,' else '' end,
      case when same_street then 'same_street,' else '' end,
      case when same_city_state then 'same_city_state' else '' end
    ), r',+$', '')) as address_match_propensity
  from address_propensity_raw
  where same_practice or same_zip9 or same_zip5 or same_street or same_city_state
),
billing_based_pairs as (
  select
    bo.org_npi,
    cast(m.servicing_npi as string) as servicing_npi,
    'billing_npi' as source_type,
    cast(null as string) as address_match_type,
    cast(null as string) as address_match_propensity
  from {{ ref('stg_doge') }} m
  inner join (select lpad(trim(cast(org_npi as string)), 10, '0') as org_npi_norm, org_npi from bh_orgs_any_state) bo
    on lpad(trim(cast(m.billing_npi as string)), 10, '0') = bo.org_npi_norm
  where lpad(trim(cast(m.servicing_npi as string)), 10, '0') != lpad(trim(cast(m.billing_npi as string)), 10, '0')
),
roster_pairs as (
  select org_npi, servicing_npi, source_type, address_match_type, address_match_propensity from address_based_pairs
  union all
  select org_npi, servicing_npi, source_type, address_match_type, address_match_propensity from billing_based_pairs
  qualify row_number() over (partition by org_npi, servicing_npi order by case when source_type = 'billing_npi' then 0 else 1 end) = 1
),

-- Fallback NPPES for servicing NPIs not in bh_provider_locations (e.g. orgs, out-of-state)
servicing_nppes_fallback as (
  select
    cast(npi as string) as npi_str,
    coalesce(
      n.provider_organization_name_legal_business_name,
      concat(n.provider_last_name_legal_name, ', ', n.provider_first_name)
    ) as provider_name,
    trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) as provider_taxonomy_code,
    nucc.taxonomy_classification as provider_taxonomy_classification,
    w.classification as provider_bh_classification,
    w.bh_grouping as provider_bh_grouping,
    n.provider_first_line_business_practice_location_address as nppes_practice_line_1,
    n.provider_business_practice_location_address_city_name as nppes_practice_city,
    n.provider_business_practice_location_address_state_name as nppes_practice_state,
    n.provider_business_practice_location_address_postal_code as nppes_practice_zip,
    substr(regexp_replace(coalesce(n.provider_business_practice_location_address_postal_code, ''), r'[^0-9]', ''), 1, 9) as zip9,
    n.provider_first_line_business_mailing_address as nppes_mailing_line_1,
    n.provider_business_mailing_address_city_name as nppes_mailing_city,
    n.provider_business_mailing_address_state_name as nppes_mailing_state,
    n.provider_business_mailing_address_postal_code as nppes_mailing_zip,
    regexp_replace(lower(coalesce(n.provider_first_line_business_practice_location_address, '')), r'[^a-z0-9]', '') as addr_clean_full
  from {{ source('nppes_public', 'npi_raw') }} n
  left join {{ ref('nucc_lookup') }} nucc on trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) = nucc.taxonomy_code
  left join {{ ref('stg_bh_taxonomy_whitelist') }} w on n.healthcare_provider_taxonomy_code_1 = w.code
),

base as (
  select
    r.org_npi,
    r.servicing_npi,
    r.source_type,
    r.address_match_type,
    r.address_match_propensity,
    o.org_name,
    o.org_taxonomy_code,
    o.org_taxonomy_classification,
    o.org_bh_grouping,
    o.org_address_line_1,
    o.org_city,
    o.org_state,
    o.org_zip,
    o.org_zip9,
    o.addr_clean_full as org_addr_clean,
    coalesce(p.provider_name, f.provider_name) as servicing_provider_name,
    coalesce(p.provider_taxonomy_code, f.provider_taxonomy_code) as provider_taxonomy_code,
    coalesce(p.provider_taxonomy_classification, f.provider_taxonomy_classification) as provider_taxonomy_classification,
    coalesce(p.provider_bh_classification, f.provider_bh_classification) as provider_bh_classification,
    coalesce(p.provider_bh_grouping, f.provider_bh_grouping) as provider_bh_grouping,
    coalesce(p.nppes_practice_line_1, f.nppes_practice_line_1) as nppes_practice_line_1,
    coalesce(p.nppes_practice_city, f.nppes_practice_city) as nppes_practice_city,
    coalesce(p.nppes_practice_state, f.nppes_practice_state) as nppes_practice_state,
    coalesce(p.nppes_practice_zip, f.nppes_practice_zip) as nppes_practice_zip,
    coalesce(p.zip9, f.zip9) as servicing_zip9,
    coalesce(p.addr_clean_full, f.addr_clean_full) as servicing_addr_clean,
    coalesce(p.nppes_mailing_line_1, f.nppes_mailing_line_1) as nppes_mailing_line_1,
    coalesce(p.nppes_mailing_city, f.nppes_mailing_city) as nppes_mailing_city,
    coalesce(p.nppes_mailing_state, f.nppes_mailing_state) as nppes_mailing_state,
    coalesce(p.nppes_mailing_zip, f.nppes_mailing_zip) as nppes_mailing_zip,
    coalesce(p.taxonomy_class, f.provider_taxonomy_classification) as taxonomy_class,
    coalesce(d.bldg_org_count, 0) as bldg_org_count,
    b.claims_2024_count,
    b.total_claims_3yr,
    b.total_spend_3yr,
    b.total_beneficiaries_3yr,
    b.avg_beneficiaries_per_month_3yr,
    b.months_with_claims_3yr,
    b.last_active_month,
    dn.npi_total_claims_3yr,
    dn.npi_total_spend_3yr,
    dn.npi_avg_beneficiaries_per_month_3yr,
    m.pml_provider_name,
    m.pml_address_line_1,
    m.pml_city,
    m.pml_state,
    m.pml_zip,
    m.pml_zip9,
    m.pml_contract_effective_date,
    m.pml_contract_end_date
  from roster_pairs r
  inner join bh_orgs_any_state o on r.org_npi = o.org_npi
  left join {{ ref('bh_provider_locations') }} p on r.servicing_npi = p.npi_str
  left join servicing_nppes_fallback f on r.servicing_npi = f.npi_str and p.npi_str is null
  left join bldg_density d on o.org_zip9 = d.zip9
  left join doge_pair_3yr b on r.org_npi = b.billing_npi and r.servicing_npi = b.servicing_npi
  left join doge_npi_3yr dn on r.servicing_npi = dn.npi
  left join pml_by_npi m on r.servicing_npi = m.npi
)

select
  org_npi,
  org_name,
  source_type,
  address_match_type,
  address_match_propensity,
  org_taxonomy_code,
  org_taxonomy_classification,
  org_bh_grouping as org_taxonomy_bh_grouping,
  org_address_line_1 as site_address_line_1,
  org_city as site_city,
  org_state as site_state,
  org_zip as site_zip,
  org_zip9 as site_zip9,
  org_taxonomy_code as site_taxonomy_code,
  org_taxonomy_classification as site_taxonomy_classification,
  org_bh_grouping as site_taxonomy_bh_grouping,
  servicing_npi,
  servicing_provider_name,
  provider_taxonomy_code,
  provider_taxonomy_classification,
  provider_bh_classification,
  provider_bh_grouping as provider_taxonomy_bh_grouping,
  taxonomy_class as specialty,
  nppes_practice_line_1,
  nppes_practice_city,
  nppes_practice_state,
  nppes_practice_zip,
  servicing_zip9,
  nppes_mailing_line_1,
  nppes_mailing_city,
  nppes_mailing_state,
  pml_provider_name,
  pml_address_line_1,
  pml_city as pml_city,
  pml_state as pml_state,
  pml_zip as pml_zip,
  pml_zip9,
  pml_contract_effective_date,
  pml_contract_end_date,
  (pml_provider_name is not null) as in_pml,
  (nppes_practice_line_1 is not null and trim(nppes_practice_line_1) != '') as nppes_practice_address_complete,
  (pml_zip9 is not null and servicing_zip9 is not null and pml_zip9 = servicing_zip9) as nppes_pml_zip9_match,
  (org_addr_clean = servicing_addr_clean) as org_site_exact_match,
  coalesce(total_claims_3yr, 0) as total_claims_3yr,
  coalesce(total_spend_3yr, 0) as total_spend_3yr,
  coalesce(avg_beneficiaries_per_month_3yr, 0) as avg_beneficiaries_per_month_3yr,
  coalesce(months_with_claims_3yr, 0) as months_with_claims_3yr,
  last_active_month,
  coalesce(npi_total_claims_3yr, 0) as npi_total_claims_3yr,
  coalesce(npi_total_spend_3yr, 0) as npi_total_spend_3yr,
  coalesce(npi_avg_beneficiaries_per_month_3yr, 0) as npi_avg_beneficiaries_per_month_3yr,
  case
    when claims_2024_count > 0 and org_addr_clean = servicing_addr_clean then 100
    when org_addr_clean = servicing_addr_clean then 85
    when source_type = 'billing_npi' and claims_2024_count > 0 then 90
    when source_type = 'billing_npi' and coalesce(total_claims_3yr, 0) > 0 then 70
    when source_type = 'address' and address_match_type = 'strong' and org_zip9 = servicing_zip9 and bldg_org_count <= 2 then 75
    when source_type = 'address' and address_match_type = 'strong' then 70
    when source_type = 'address' and address_match_type = 'partial' then 50
    when coalesce(total_claims_3yr, 0) > 0 then 60
    when org_zip9 = servicing_zip9 and bldg_org_count >= 10 then 30
    when org_zip9 = servicing_zip9 then 50
    when source_type = 'billing_npi' then 55
    else 0
  end as confidence_score,
  trim(concat(
    case when source_type = 'billing_npi' then 'Billing-based: linked via DOGE claims. '
      when source_type = 'address' and address_match_type = 'strong' then 'Address-based (strong): same suite/address or ZIP+9. '
      when source_type = 'address' and address_match_type = 'partial' then 'Address-based (partial): same ZIP5, street, or city+state. '
      when source_type = 'address' then 'Address-based: co-located. ' else '' end,
    case when claims_2024_count > 0 and org_addr_clean = servicing_addr_clean
      then format('Verified Active: Shares suite, %d claims in 2024. 3yr: %d claims, $%.0f, ~%.0f avg beneficiaries/mo. ', cast(claims_2024_count as int64), cast(coalesce(total_claims_3yr, 0) as int64), coalesce(total_spend_3yr, 0), coalesce(avg_beneficiaries_per_month_3yr, 0)) else '' end,
    case when coalesce(total_claims_3yr, 0) > 0 and (claims_2024_count is null or claims_2024_count = 0)
      then format('Historical: %d claims, $%.0f spend (3yr); none in 2024. ', cast(total_claims_3yr as int64), coalesce(total_spend_3yr, 0)) else '' end,
    case when bldg_org_count <= 2 and taxonomy_class is not null
      then 'Likely: Specialist at an isolated behavioral facility; shared building makes the link probable. ' else '' end,
    case when bldg_org_count >= 10
      then 'Weak Match: Shared building, but high-density hub with many unrelated offices. ' else '' end,
    case when org_addr_clean = servicing_addr_clean and (claims_2024_count is null or claims_2024_count = 0)
      then 'Exact suite match; no 2024 billing data found. ' else '' end,
    case when org_zip9 = servicing_zip9 and (org_addr_clean != servicing_addr_clean or org_addr_clean is null)
      then 'Building match: shared location; suite-level or 2024 billing data missing. ' else '' end,
    '— Org: ', coalesce(org_name, 'Unknown'), ' at ', coalesce(org_address_line_1, ''), ', ', coalesce(org_city, ''), ' ', coalesce(org_state, ''),
    '. NPPES: ', coalesce(nppes_practice_line_1, 'no practice address'), '. ',
    case when pml_provider_name is not null
      then 'PML enrolled. '
      else 'Not in PML. ' end,
    case when pml_zip9 is not null and servicing_zip9 is not null and pml_zip9 = servicing_zip9
      then 'NPPES practice ZIP+4 matches PML. '
      when pml_zip9 is not null and servicing_zip9 is not null
      then 'NPPES practice ZIP+4 does not match PML. '
      else '' end
  )) as roster_explanation
from base
