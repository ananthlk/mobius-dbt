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

-- BH orgs = UNION of (a) entity type 2 organizations, (b) entity type 1 individuals who bill (appear as billing_npi in DOGE).
-- Outpatient/professional services often bill under entity type 1; their practice locations count as locations.
bh_orgs_type2 as (
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
bh_orgs_type1_billing as (
  select
    cast(n.npi as string) as org_npi,
    coalesce(p.provider_name, concat(n.provider_last_name_legal_name, ', ', n.provider_first_name)) as org_name,
    trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) as org_taxonomy_code,
    nucc.taxonomy_classification as org_taxonomy_classification,
    w.bh_grouping as org_bh_grouping,
    coalesce(n.provider_first_line_business_practice_location_address, p.address_line_1) as org_address_line_1,
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
  inner join (
    select distinct cast(billing_npi as string) as billing_npi
    from {{ ref('stg_doge') }}
    where substr(safe_cast(period_month as string), 1, 6) >= '202202'
  ) doge on cast(n.npi as string) = doge.billing_npi
  left join {{ source('landing_medicaid_npi', 'stg_pml') }} p
    on cast(n.npi as string) = cast(p.npi as string)
  left join {{ ref('nucc_lookup') }} nucc
    on trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) = nucc.taxonomy_code
  inner join {{ ref('stg_bh_taxonomy_whitelist') }} w
    on n.healthcare_provider_taxonomy_code_1 = w.code
  where n.entity_type_code = 1
    and (
      n.provider_business_practice_location_address_state_name = '{{ var("state_code", "FL") }}'
      or n.provider_license_number_state_code_1 = '{{ var("state_code", "FL") }}'
    )
),
bh_orgs as (
  select * from bh_orgs_type2
  union distinct
  select * from bh_orgs_type1_billing
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
    substr(
      case
        when length(regexp_replace(coalesce(cast(zip as string), ''), r'[^0-9]', '')) >= 9
        then regexp_replace(coalesce(cast(zip as string), ''), r'[^0-9]', '')
        else regexp_replace(concat(coalesce(cast(zip as string), ''), coalesce(cast(zip_plus_4 as string), '')), r'[^0-9]', '')
      end,
      1, 9
    ) as pml_zip9
  from {{ source('landing_medicaid_npi', 'stg_pml') }}
  where npi is not null
  qualify row_number() over (partition by cast(npi as string) order by contract_effective_date desc nulls last) = 1
),

-- BH orgs from any state (for billing-based: DOGE has national data; match by taxonomy).
-- Same union: entity type 2 + entity type 1 who bill.
bh_orgs_type2_any_state as (
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
bh_orgs_type1_billing_any_state as (
  select
    cast(n.npi as string) as org_npi,
    coalesce(p.provider_name, concat(n.provider_last_name_legal_name, ', ', n.provider_first_name)) as org_name,
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
  inner join (
    select distinct cast(billing_npi as string) as billing_npi
    from {{ ref('stg_doge') }}
    where substr(safe_cast(period_month as string), 1, 6) >= '202202'
  ) doge on cast(n.npi as string) = doge.billing_npi
  left join {{ source('landing_medicaid_npi', 'stg_pml') }} p on cast(n.npi as string) = cast(p.npi as string)
  left join {{ ref('nucc_lookup') }} nucc on trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) = nucc.taxonomy_code
  inner join {{ ref('stg_bh_taxonomy_whitelist') }} w on n.healthcare_provider_taxonomy_code_1 = w.code
  where n.entity_type_code = 1
),
bh_orgs_any_state as (
  select * from bh_orgs_type2_any_state
  union distinct
  select * from bh_orgs_type1_billing_any_state
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

-- Points-based matching: address signals (NPPES + PML). Billing pairs are separate (DOGE-linked).
-- Weights: billing_2024=45, billing_historical=35, nppes_addr=25, pml_addr=20, zip9=18, pml_zip9=15, zip5=6, city_state=3.
-- Qualification: match_score >= 28. Normalization: case-insensitive, alphanumeric for address; trim for city/state.
match_score_threshold as (select 28 as min_score),

-- Address normalization: lower, collapse spaces, alphanumeric only (handles ST vs STREET via consistent form).
org_addr_norm as (
  select
    org_npi,
    org_address_line_1,
    org_city,
    org_state,
    org_zip,
    org_zip9,
    addr_clean_full as org_addr_clean
  from bh_orgs
),
candidates_geo as (
  select
    o.org_npi,
    p.npi_str as servicing_npi,
    o.org_addr_clean,
    o.org_zip9,
    o.org_city,
    o.org_state,
    coalesce(p.addr_clean_full, '') as nppes_addr_clean,
    coalesce(p.zip9, '') as nppes_zip9,
    coalesce(p.nppes_practice_city, '') as nppes_city,
    coalesce(p.nppes_practice_state, '') as nppes_state
  from org_addr_norm o
  inner join {{ ref('bh_provider_locations') }} p
    on (
      (o.org_zip9 is not null and p.zip9 is not null and length(o.org_zip9) >= 5 and length(p.zip9) >= 5 and substr(o.org_zip9, 1, 5) = substr(p.zip9, 1, 5))
      or (o.org_zip9 is null and p.zip9 is null and upper(trim(coalesce(o.org_city,''))) = upper(trim(coalesce(p.nppes_practice_city,''))) and upper(trim(coalesce(o.org_state,''))) = upper(trim(coalesce(p.nppes_practice_state,'')))
          and length(trim(o.org_city)) > 0 and length(trim(o.org_state)) > 0)
    )
  where o.org_npi != p.npi_str
),
candidates_with_pml as (
  select
    c.*,
    coalesce(regexp_replace(lower(coalesce(m.pml_address_line_1, '')), r'[^a-z0-9]', ''), '') as pml_addr_clean,
    coalesce(m.pml_zip9, '') as pml_zip9
  from candidates_geo c
  left join pml_by_npi m on c.servicing_npi = m.npi
),
billing_candidates as (
  select org_npi, servicing_npi from billing_based_pairs
),
address_match_points as (
  select
    c.org_npi,
    c.servicing_npi,
    (case when o.org_addr_clean is not null and c.nppes_addr_clean is not null and o.org_addr_clean = c.nppes_addr_clean then 25 else 0 end) +
    (case when o.org_addr_clean is not null and c.pml_addr_clean is not null and length(trim(c.pml_addr_clean)) > 0 and o.org_addr_clean = c.pml_addr_clean then 20 else 0 end) +
    (case when o.org_zip9 is not null and c.nppes_zip9 is not null and length(o.org_zip9) >= 5 and length(c.nppes_zip9) >= 5 and o.org_zip9 = c.nppes_zip9 then 18 else 0 end) +
    (case when o.org_zip9 is not null and c.pml_zip9 is not null and length(c.pml_zip9) >= 5 and o.org_zip9 = c.pml_zip9 then 15 else 0 end) +
    (case when o.org_zip9 is not null and c.nppes_zip9 is not null and length(o.org_zip9) >= 5 and length(c.nppes_zip9) >= 5 and substr(o.org_zip9, 1, 5) = substr(c.nppes_zip9, 1, 5) and o.org_zip9 != c.nppes_zip9 then 6 else 0 end) +
    (case when length(trim(o.org_city)) > 0 and length(trim(c.nppes_city)) > 0 and upper(trim(o.org_city)) = upper(trim(c.nppes_city))
          and length(trim(o.org_state)) > 0 and length(trim(c.nppes_state)) > 0 and upper(trim(o.org_state)) = upper(trim(c.nppes_state)) then 3 else 0 end)
    as match_score,
    concat(
      case when o.org_addr_clean = c.nppes_addr_clean and o.org_addr_clean is not null then 'nppes_addr,' else '' end,
      case when o.org_addr_clean = c.pml_addr_clean and c.pml_addr_clean != '' then 'pml_addr,' else '' end,
      case when o.org_zip9 = c.nppes_zip9 and length(o.org_zip9) >= 5 then 'nppes_zip9,' else '' end,
      case when o.org_zip9 = c.pml_zip9 and length(c.pml_zip9) >= 5 then 'pml_zip9,' else '' end,
      case when substr(o.org_zip9, 1, 5) = substr(c.nppes_zip9, 1, 5) and length(o.org_zip9) >= 5 and length(c.nppes_zip9) >= 5 then 'zip5,' else '' end,
      case when upper(trim(o.org_city)) = upper(trim(c.nppes_city)) and upper(trim(o.org_state)) = upper(trim(c.nppes_state)) and length(trim(o.org_city)) > 0 then 'city_state' else '' end
    ) as match_breakdown
  from candidates_with_pml c
  inner join org_addr_norm o on c.org_npi = o.org_npi
  left join billing_candidates bc on c.org_npi = bc.org_npi and c.servicing_npi = bc.servicing_npi
  where bc.org_npi is null
),
address_based_pairs as (
  select
    org_npi,
    servicing_npi,
    'address' as source_type,
    case when match_score >= 50 then 'strong' when match_score >= 35 then 'medium' when match_score >= 28 then 'partial' else null end as address_match_type,
    trim(regexp_replace(match_breakdown, r',+$', '')) as address_match_propensity
  from address_match_points
  cross join match_score_threshold t
  where match_score >= t.min_score
),
roster_pairs as (
  select org_npi, servicing_npi, source_type, address_match_type, address_match_propensity from address_based_pairs
  union all
  select org_npi, servicing_npi, source_type, address_match_type, address_match_propensity from billing_based_pairs
  qualify row_number() over (partition by org_npi, servicing_npi order by case when source_type = 'billing_npi' then 0 else 1 end) = 1
),
-- Servicing NPI bills under another org in DOGE → very low confidence (we only inferred roster from address; they likely belong elsewhere).
servicing_bills_under_other_org as (
  select
    r.org_npi,
    r.servicing_npi,
    logical_or(d.billing_npi != r.org_npi) as has_billing_under_other_org
  from roster_pairs r
  inner join doge_pair_3yr d on d.servicing_npi = r.servicing_npi
  group by r.org_npi, r.servicing_npi
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
    m.pml_contract_end_date,
    coalesce(ob.has_billing_under_other_org, false) as has_billing_under_other_org
  from roster_pairs r
  inner join bh_orgs_any_state o on r.org_npi = o.org_npi
  left join {{ ref('bh_provider_locations') }} p on r.servicing_npi = p.npi_str
  left join servicing_nppes_fallback f on r.servicing_npi = f.npi_str and p.npi_str is null
  left join servicing_bills_under_other_org ob on r.org_npi = ob.org_npi and r.servicing_npi = ob.servicing_npi
  left join bldg_density d on o.org_zip9 = d.zip9
  left join doge_pair_3yr b on r.org_npi = b.billing_npi and r.servicing_npi = b.servicing_npi
  left join doge_npi_3yr dn on r.servicing_npi = dn.npi
  left join pml_by_npi m on r.servicing_npi = m.npi
)

-- Site derivation: base = org address; additional = servicing NPI practice addresses from DOGE (NPPES/PML union, dedup).
-- For billing-based rows: use servicing NPI address when different from org → additional site. Else org base.
-- For address-based rows: use org address (base site).
select
  org_npi,
  org_name,
  source_type,
  address_match_type,
  address_match_propensity,
  org_taxonomy_code,
  org_taxonomy_classification,
  org_bh_grouping as org_taxonomy_bh_grouping,
  case
    when source_type = 'billing_npi'
      and trim(coalesce(nppes_practice_line_1, pml_address_line_1)) != ''
      and (
        coalesce(servicing_addr_clean, '') != coalesce(org_addr_clean, '')
        or (coalesce(servicing_zip9, pml_zip9) is not null and org_zip9 is not null and coalesce(servicing_zip9, pml_zip9) != org_zip9)
      )
    then coalesce(nppes_practice_line_1, pml_address_line_1)
    else org_address_line_1
  end as site_address_line_1,
  case
    when source_type = 'billing_npi'
      and trim(coalesce(nppes_practice_line_1, pml_address_line_1)) != ''
      and (
        coalesce(servicing_addr_clean, '') != coalesce(org_addr_clean, '')
        or (coalesce(servicing_zip9, pml_zip9) is not null and org_zip9 is not null and coalesce(servicing_zip9, pml_zip9) != org_zip9)
      )
    then coalesce(nppes_practice_city, pml_city)
    else org_city
  end as site_city,
  case
    when source_type = 'billing_npi'
      and trim(coalesce(nppes_practice_line_1, pml_address_line_1)) != ''
      and (
        coalesce(servicing_addr_clean, '') != coalesce(org_addr_clean, '')
        or (coalesce(servicing_zip9, pml_zip9) is not null and org_zip9 is not null and coalesce(servicing_zip9, pml_zip9) != org_zip9)
      )
    then coalesce(nppes_practice_state, pml_state)
    else org_state
  end as site_state,
  case
    when source_type = 'billing_npi'
      and trim(coalesce(nppes_practice_line_1, pml_address_line_1)) != ''
      and (
        coalesce(servicing_addr_clean, '') != coalesce(org_addr_clean, '')
        or (coalesce(servicing_zip9, pml_zip9) is not null and org_zip9 is not null and coalesce(servicing_zip9, pml_zip9) != org_zip9)
      )
    then coalesce(nppes_practice_zip, pml_zip)
    else org_zip
  end as site_zip,
  case
    when source_type = 'billing_npi'
      and trim(coalesce(nppes_practice_line_1, pml_address_line_1)) != ''
      and (
        coalesce(servicing_addr_clean, '') != coalesce(org_addr_clean, '')
        or (coalesce(servicing_zip9, pml_zip9) is not null and org_zip9 is not null and coalesce(servicing_zip9, pml_zip9) != org_zip9)
      )
    then coalesce(servicing_zip9, pml_zip9)
    else org_zip9
  end as site_zip9,
  case
    when source_type = 'billing_npi'
      and trim(coalesce(nppes_practice_line_1, pml_address_line_1)) != ''
      and (
        coalesce(servicing_addr_clean, '') != coalesce(org_addr_clean, '')
        or (coalesce(servicing_zip9, pml_zip9) is not null and org_zip9 is not null and coalesce(servicing_zip9, pml_zip9) != org_zip9)
      )
    then 'additional'
    else 'base'
  end as site_source,
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
  -- Four-tier confidence: Perfect / Good / Medium / Low (see docs)
  case
    -- Low: address-only link but NPI bills under another org → likely not this org's roster
    when has_billing_under_other_org and source_type = 'address' and (total_claims_3yr is null or total_claims_3yr = 0) then 15
    when has_billing_under_other_org and source_type = 'address' then 25
    -- Perfect: same address + zip9 + historic billing
    when coalesce(total_claims_3yr, 0) > 0 and org_addr_clean = servicing_addr_clean and org_zip9 = servicing_zip9 then 100
    when coalesce(total_claims_3yr, 0) > 0 and address_match_type in ('strong', 'medium') and org_zip9 = servicing_zip9 then 95
    -- Good: historic billing + (zip9 OR address) — needs PML/combo work
    when source_type = 'billing_npi' and claims_2024_count > 0 then 90
    when source_type = 'billing_npi' and coalesce(total_claims_3yr, 0) > 0 then 80
    when coalesce(total_claims_3yr, 0) > 0 and (org_zip9 = servicing_zip9 or address_match_type in ('strong', 'medium')) then 75
    when coalesce(total_claims_3yr, 0) > 0 then 70
    -- Medium: same address + zip9, no billing — likely new joiners post-2024
    when org_addr_clean = servicing_addr_clean and org_zip9 = servicing_zip9 then 60
    when address_match_type in ('strong', 'medium') and org_zip9 = servicing_zip9 and bldg_org_count <= 3 then 55
    when address_match_type in ('strong', 'medium') and org_zip9 = servicing_zip9 then 50
    -- Low: partial address only — verify before acting
    when address_match_type = 'partial' and bldg_org_count <= 3 then 45
    when address_match_type = 'partial' then 35
    when org_zip9 = servicing_zip9 and bldg_org_count >= 10 then 25
    when org_zip9 = servicing_zip9 and bldg_org_count >= 5 then 30
    when org_zip9 = servicing_zip9 then 40
    when source_type = 'billing_npi' then 50
    else 25
  end as confidence_score,
  trim(concat(
    case when source_type = 'billing_npi' then 'Billing-based: linked via DOGE claims. '
      when source_type = 'address' and address_match_type = 'strong' then 'Address-based (strong): same suite/address or ZIP+9. '
      when source_type = 'address' and address_match_type = 'medium' then 'Address-based (medium): points-based match (e.g. ZIP9, PML). '
      when source_type = 'address' and address_match_type = 'partial' then 'Address-based (partial): points above threshold (ZIP5, city+state). '
      when source_type = 'address' then 'Address-based: co-located. ' else '' end,
    case when has_billing_under_other_org and source_type = 'address'
      then 'Very low confidence: This NPI bills under another organization in claims data; roster link is address-only—verify before acting. ' else '' end,
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
