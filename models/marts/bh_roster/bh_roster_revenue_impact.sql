{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- BH Roster Revenue Impact: estimated revenue (low/mid/high) per readiness row.
-- Joins bh_roster_readiness to fl_medicaid_taxonomy_revenue_rates.
-- Consumed by Python provider-roster-credentialing skill and LLM report generation.
-- For invalid combos: estimate = beneficiaries_per_provider (state median) × revenue_per_beneficiary (p25/p50/p75).

with readiness as (
  select * from {{ ref('bh_roster_readiness') }}
),

rates as (
  select * from {{ ref('fl_medicaid_taxonomy_revenue_rates') }}
),

joined as (
  select
    r.*,
    trim(cast(r.provider_taxonomy_code as string)) as tax_code,
    rt.revenue_per_beneficiary_p25,
    rt.revenue_per_beneficiary_p50,
    rt.revenue_per_beneficiary_p75,
    rt.beneficiaries_per_provider_median,
    rt.in_tml
  from readiness r
  left join rates rt on trim(cast(r.provider_taxonomy_code as string)) = rt.provider_taxonomy_code
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
  readiness_status,
  readiness_summary,
  pml_credentialed_combos,
  suggested_action,
  suggested_taxonomies,
  -- Revenue impact: only for invalid combos; uses state taxonomy rates (per-beneficiary × beneficiaries per provider)
  case
    when readiness_all_pass then 0
    when beneficiaries_per_provider_median is null or revenue_per_beneficiary_p25 is null then 0
    else round(beneficiaries_per_provider_median * revenue_per_beneficiary_p25, 2)
  end as est_revenue_low,
  case
    when readiness_all_pass then 0
    when beneficiaries_per_provider_median is null or revenue_per_beneficiary_p50 is null then 0
    else round(beneficiaries_per_provider_median * revenue_per_beneficiary_p50, 2)
  end as est_revenue_mid,
  case
    when readiness_all_pass then 0
    when beneficiaries_per_provider_median is null or revenue_per_beneficiary_p75 is null then 0
    else round(beneficiaries_per_provider_median * revenue_per_beneficiary_p75, 2)
  end as est_revenue_high,
  case when readiness_all_pass then null when tax_code is not null and (revenue_per_beneficiary_p50 is not null) then 'state' else null end as revenue_source,
  (not check_3_taxonomy_permitted_pass) as is_deprecated_taxonomy,
  beneficiaries_per_provider_median as assumed_beneficiaries_per_provider
from joined
