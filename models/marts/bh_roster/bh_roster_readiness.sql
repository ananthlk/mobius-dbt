{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- BH Roster Readiness: Medicaid NPI initiative checks per (org, servicing_npi, taxonomy).
-- Expands to ALL NPPES taxonomies (1-15) per roster row. NPPES A,B,C → 3 rows.
-- B in PML = Ready; A on TML but not PML = Opportunity (flag if higher revenue); C not on TML = Not supported.

with roster as (
  select * from {{ ref('bh_roster') }}
),

-- Expand roster by all NPPES taxonomies per servicing NPI
roster_expanded as (
  select
    r.org_npi,
    r.org_name,
    r.source_type,
    r.address_match_type,
    r.address_match_propensity,
    r.site_address_line_1,
    r.site_city,
    r.site_state,
    r.site_zip,
    r.servicing_npi,
    r.servicing_provider_name,
    t.taxonomy_code as provider_taxonomy_code,
    t.is_primary as taxonomy_is_primary,
    r.servicing_zip9,
    r.in_pml,
    r.pml_provider_name,
    r.pml_zip9,
    r.nppes_practice_line_1,
    r.nppes_practice_city,
    r.nppes_practice_state,
    r.nppes_practice_zip,
    r.confidence_score,
    r.total_claims_3yr
  from roster r
  inner join {{ ref('bh_nppes_taxonomies_unpivoted') }} t on r.servicing_npi = t.npi
),

-- FL allowed taxonomy (TML)
fl_tml as (
  select distinct trim(cast(taxonomy_code as string)) as taxonomy_code
  from {{ source('landing_medicaid_npi', 'stg_tml') }}
  where taxonomy_code is not null and trim(cast(taxonomy_code as string)) != ''
),

-- PML: build zip9 and contract validity per row
pml_detail as (
  select
    cast(npi as string) as npi,
    cast(medicaid_provider_id as string) as medicaid_provider_id,
    trim(cast(taxonomy_code as string)) as pml_taxonomy_code,
    substr(regexp_replace(concat(coalesce(zip, ''), coalesce(zip_plus_4, '')), r'[^0-9]', ''), 1, 9) as pml_zip9,
    contract_effective_date,
    contract_end_date,
    current_date('America/New_York') between coalesce(contract_effective_date, date '1900-01-01')
      and coalesce(contract_end_date, date '9999-12-31') as contract_valid
  from {{ source('landing_medicaid_npi', 'stg_pml') }}
  where npi is not null
),

-- Check 1: NPI in PML
check1 as (
  select
    r.org_npi,
    r.servicing_npi,
    r.provider_taxonomy_code,
    (p.npi is not null) as check_1_npi_in_pml_pass,
    case
      when p.npi is not null then 'NPI is enrolled in PML (Provider Master List) and has a Medicaid ID.'
      else 'NPI is not in PML. Provider must be enrolled in Florida Medicaid to bill.'
    end as check_1_npi_in_pml_explanation
  from roster_expanded r
  left join (select distinct npi from pml_detail) p on r.servicing_npi = p.npi
),

-- Check 2: ZIP+4 valid
check2 as (
  select
    org_npi,
    servicing_npi,
    provider_taxonomy_code,
    (servicing_zip9 is not null and length(trim(servicing_zip9)) = 9 and regexp_contains(servicing_zip9, r'^\d{9}$')) as check_2_zip9_valid_pass,
    case
      when servicing_zip9 is null or trim(servicing_zip9) = '' then 'NPPES practice address has no ZIP+4. Full 9-digit ZIP+4 is required for Medicaid claims.'
      when length(trim(servicing_zip9)) != 9 or not regexp_contains(servicing_zip9, r'^\d{9}$')
        then 'NPPES practice ZIP+4 is not 9 digits. Expect ZIP5 + 4-digit extension (e.g. 123451234).'
      else 'NPPES practice address has valid 9-digit ZIP+4.'
    end as check_2_zip9_valid_explanation
  from roster_expanded
),

-- Check 3: Taxonomy permitted in FL (TML)
check3 as (
  select
    r.org_npi,
    r.servicing_npi,
    r.provider_taxonomy_code,
    (t.taxonomy_code is not null) as check_3_taxonomy_permitted_pass,
    case
      when r.provider_taxonomy_code is null or trim(cast(r.provider_taxonomy_code as string)) = ''
        then 'Provider has no taxonomy in NPPES. A valid taxonomy is required.'
      when t.taxonomy_code is null
        then 'Provider taxonomy ' || coalesce(r.provider_taxonomy_code, '') || ' is not on the FL Medicaid Taxonomy Master List (TML).'
      else 'Provider taxonomy is permitted in Florida Medicaid (on TML).'
    end as check_3_taxonomy_permitted_explanation
  from roster_expanded r
  left join fl_tml t on trim(cast(r.provider_taxonomy_code as string)) = t.taxonomy_code
),

-- Check 4: NPI + taxonomy + ZIP9 combo in PML
pml_combo_match as (
  select
    r.org_npi,
    r.servicing_npi,
    r.provider_taxonomy_code,
    countif(m.npi is not null) > 0 as has_combo_match
  from roster_expanded r
  left join pml_detail m
    on r.servicing_npi = m.npi
    and length(substr(regexp_replace(coalesce(r.servicing_zip9, ''), r'[^0-9]', ''), 1, 9)) = 9
    and substr(regexp_replace(coalesce(r.servicing_zip9, ''), r'[^0-9]', ''), 1, 9) =
        substr(regexp_replace(coalesce(m.pml_zip9, ''), r'[^0-9]', ''), 1, 9)
    and trim(cast(r.provider_taxonomy_code as string)) = trim(coalesce(m.pml_taxonomy_code, ''))
    and m.contract_valid
  group by 1, 2, 3
),

check4 as (
  select
    c.org_npi,
    c.servicing_npi,
    c.provider_taxonomy_code,
    c.has_combo_match as check_4_combo_medicaid_id_pass,
    case
      when c.has_combo_match then 'PML has a valid Medicaid ID for this NPI + taxonomy + service location (ZIP+4) with active contract.'
      when not r.in_pml then 'Cannot verify combo: NPI not in PML.'
      when r.servicing_zip9 is null or length(trim(coalesce(r.servicing_zip9, ''))) != 9 or not regexp_contains(trim(r.servicing_zip9), r'^\d{9}$')
        then 'Cannot verify combo: NPPES practice ZIP+4 is not 9 digits. Update address in NPPES.'
      else 'PML has no matching row for NPI + taxonomy + ZIP+4 with valid contract. Add taxonomy to PML or align service location.'
    end as check_4_combo_medicaid_id_explanation
  from pml_combo_match c
  inner join roster_expanded r
    on c.org_npi = r.org_npi and c.servicing_npi = r.servicing_npi and c.provider_taxonomy_code = r.provider_taxonomy_code
),

-- Revenue rates by taxonomy (for opportunity: higher revenue potential)
tax_revenue as (
  select
    provider_taxonomy_code,
    coalesce(revenue_per_beneficiary_p50, 0) as revenue_per_beneficiary_p50
  from {{ ref('fl_medicaid_taxonomy_revenue_rates') }}
),

-- Max revenue per NPI from their PML taxonomies (for comparison)
pml_tax_revenue as (
  select
    m.npi,
    max(coalesce(tr.revenue_per_beneficiary_p50, 0)) as max_pml_revenue_per_ben
  from pml_detail m
  left join tax_revenue tr on trim(m.pml_taxonomy_code) = tr.provider_taxonomy_code
  where m.contract_valid
  group by 1
),

-- Top co-occurring taxonomies (for suggested_action)
top_cooccur_per_taxonomy as (
  select primary_taxonomy,
    string_agg(concat(cooccurring_taxonomy, '|', cast(pct as string), '|', cast(npi_count_both as string)), '; ' order by pct desc) as suggested_taxonomies
  from (
    select primary_taxonomy, cooccurring_taxonomy, pct, npi_count_both,
      row_number() over (partition by primary_taxonomy order by pct desc) as rn
    from {{ ref('taxonomy_cooccurrence_fl') }}
  )
  where rn <= 5
  group by primary_taxonomy
),

pml_combos_per_npi as (
  select npi,
    string_agg(distinct concat(trim(coalesce(pml_taxonomy_code, '')), '@', trim(coalesce(pml_zip9, ''))), '; ' order by concat(trim(coalesce(pml_taxonomy_code, '')), '@', trim(coalesce(pml_zip9, '')))) as pml_credentialed_combos
  from pml_detail
  where contract_valid and length(trim(coalesce(pml_zip9, ''))) = 9 and regexp_contains(trim(pml_zip9), r'^\d{9}$')
  group by 1
),

combo_recommendations as (
  select
    r.org_npi,
    r.servicing_npi,
    r.provider_taxonomy_code,
    r.servicing_zip9,
    p.pml_credentialed_combos,
    co.suggested_taxonomies,
    case
      when p.pml_credentialed_combos is null or trim(p.pml_credentialed_combos) = '' then null
      when exists (
        select 1 from pml_detail m
        where m.npi = r.servicing_npi and m.contract_valid
          and trim(cast(r.provider_taxonomy_code as string)) = trim(coalesce(m.pml_taxonomy_code, ''))
          and substr(regexp_replace(coalesce(r.servicing_zip9, ''), r'[^0-9]', ''), 1, 9) != substr(regexp_replace(coalesce(m.pml_zip9, ''), r'[^0-9]', ''), 1, 9)
      ) then 'PML has this taxonomy at a different ZIP. Update PML service location to match NPPES, or align roster address.'
      when exists (
        select 1 from pml_detail m
        where m.npi = r.servicing_npi and m.contract_valid
          and length(substr(regexp_replace(coalesce(r.servicing_zip9, ''), r'[^0-9]', ''), 1, 9)) = 9
          and substr(regexp_replace(coalesce(r.servicing_zip9, ''), r'[^0-9]', ''), 1, 9) = substr(regexp_replace(coalesce(m.pml_zip9, ''), r'[^0-9]', ''), 1, 9)
          and trim(cast(r.provider_taxonomy_code as string)) != trim(coalesce(m.pml_taxonomy_code, ''))
      ) then 'PML has a different taxonomy at this ZIP. Add roster taxonomy to PML, or use PML taxonomy on roster.'
      else 'PML credentialed combos: ' || p.pml_credentialed_combos || '. Align roster or update PML service location/taxonomy.'
    end as suggested_action
  from roster_expanded r
  left join pml_combos_per_npi p on r.servicing_npi = p.npi
  left join top_cooccur_per_taxonomy co on trim(cast(r.provider_taxonomy_code as string)) = co.primary_taxonomy
  where r.in_pml
),

combined as (
  select
    r.*,
    c1.check_1_npi_in_pml_pass,
    c1.check_1_npi_in_pml_explanation,
    c2.check_2_zip9_valid_pass,
    c2.check_2_zip9_valid_explanation,
    c3.check_3_taxonomy_permitted_pass,
    c3.check_3_taxonomy_permitted_explanation,
    c4.check_4_combo_medicaid_id_pass,
    c4.check_4_combo_medicaid_id_explanation,
    (c1.check_1_npi_in_pml_pass and c2.check_2_zip9_valid_pass and c3.check_3_taxonomy_permitted_pass and c4.check_4_combo_medicaid_id_pass) as readiness_all_pass,
    rec.pml_credentialed_combos,
    rec.suggested_action,
    rec.suggested_taxonomies,
    -- taxonomy_row_type: ready | opportunity | not_supported
    case
      when c1.check_1_npi_in_pml_pass and c2.check_2_zip9_valid_pass and c3.check_3_taxonomy_permitted_pass and c4.check_4_combo_medicaid_id_pass then 'ready'
      when c3.check_3_taxonomy_permitted_pass and not c4.check_4_combo_medicaid_id_pass then 'opportunity'
      when not c3.check_3_taxonomy_permitted_pass then 'not_supported'
      else 'other'
    end as taxonomy_row_type,
    -- higher_revenue_potential: opportunity taxonomy has higher revenue than NPI's PML taxonomies
    case
      when c3.check_3_taxonomy_permitted_pass and not c4.check_4_combo_medicaid_id_pass
        and tr.revenue_per_beneficiary_p50 is not null and ptr.max_pml_revenue_per_ben is not null
        and tr.revenue_per_beneficiary_p50 > ptr.max_pml_revenue_per_ben
      then true
      else false
    end as higher_revenue_potential
  from roster_expanded r
  inner join check1 c1 on r.org_npi = c1.org_npi and r.servicing_npi = c1.servicing_npi and r.provider_taxonomy_code = c1.provider_taxonomy_code
  inner join check2 c2 on r.org_npi = c2.org_npi and r.servicing_npi = c2.servicing_npi and r.provider_taxonomy_code = c2.provider_taxonomy_code
  inner join check3 c3 on r.org_npi = c3.org_npi and r.servicing_npi = c3.servicing_npi and r.provider_taxonomy_code = c3.provider_taxonomy_code
  inner join check4 c4 on r.org_npi = c4.org_npi and r.servicing_npi = c4.servicing_npi and r.provider_taxonomy_code = c4.provider_taxonomy_code
  left join combo_recommendations rec
    on r.org_npi = rec.org_npi and r.servicing_npi = rec.servicing_npi and r.provider_taxonomy_code = rec.provider_taxonomy_code
  left join tax_revenue tr on trim(cast(r.provider_taxonomy_code as string)) = tr.provider_taxonomy_code
  left join pml_tax_revenue ptr on r.servicing_npi = ptr.npi
)

select
  org_npi,
  org_name,
  source_type,
  address_match_type,
  address_match_propensity,
  site_address_line_1,
  site_city,
  site_state,
  site_zip,
  servicing_npi,
  servicing_provider_name,
  provider_taxonomy_code,
  taxonomy_is_primary,
  taxonomy_row_type,
  higher_revenue_potential,
  servicing_zip9,
  in_pml,
  pml_provider_name,
  pml_zip9,
  nppes_practice_line_1,
  nppes_practice_city,
  nppes_practice_state,
  nppes_practice_zip,
  confidence_score,
  total_claims_3yr,
  check_1_npi_in_pml_pass,
  check_1_npi_in_pml_explanation,
  check_2_zip9_valid_pass,
  check_2_zip9_valid_explanation,
  check_3_taxonomy_permitted_pass,
  check_3_taxonomy_permitted_explanation,
  check_4_combo_medicaid_id_pass,
  check_4_combo_medicaid_id_explanation,
  readiness_all_pass,
  case
    when readiness_all_pass then 'Ready'
    when not check_1_npi_in_pml_pass then 'Not enrolled'
    when not check_2_zip9_valid_pass then 'Invalid address'
    when not check_3_taxonomy_permitted_pass then 'Taxonomy not permitted'
    when not check_4_combo_medicaid_id_pass then 'Combo mismatch'
    else 'Needs review'
  end as readiness_status,
  trim(concat(
    check_1_npi_in_pml_explanation, ' ',
    check_2_zip9_valid_explanation, ' ',
    check_3_taxonomy_permitted_explanation, ' ',
    check_4_combo_medicaid_id_explanation
  )) as readiness_summary,
  pml_credentialed_combos,
  suggested_action,
  suggested_taxonomies
from combined