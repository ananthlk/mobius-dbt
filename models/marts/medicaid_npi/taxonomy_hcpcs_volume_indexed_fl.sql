{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Taxonomy → HCPCS volume with utilization indexing.
-- For each (taxonomy combo, HCPCS): claims_per_beneficiary, spend_per_beneficiary,
-- and index vs cohort average for that HCPCS (probabilistic success proxy).

with vol as (
  select
    primary_taxonomy,
    t2,
    sequence_length,
    hcpcs_code,
    claim_count,
    total_paid,
    coalesce(beneficiary_count, 0) as beneficiary_count,
    npi_count
  from {{ ref('taxonomy_hcpcs_volume_fl') }}
),
-- Cohort stats per HCPCS (mean, stddev across taxonomy combos)
vol_with_rates as (
  select
    primary_taxonomy,
    t2,
    sequence_length,
    hcpcs_code,
    claim_count,
    total_paid,
    beneficiary_count,
    npi_count,
    safe_divide(claim_count, beneficiary_count) as claims_per_beneficiary,
    safe_divide(total_paid, beneficiary_count) as spend_per_beneficiary
  from vol
  where beneficiary_count > 0
),
hcpcs_stats as (
  select
    hcpcs_code,
    avg(claims_per_beneficiary) as avg_claims_per_beneficiary,
    ifnull(stddev_samp(claims_per_beneficiary), 0) as stddev_claims_per_beneficiary,
    avg(spend_per_beneficiary) as avg_spend_per_beneficiary,
    ifnull(stddev_samp(spend_per_beneficiary), 0) as stddev_spend_per_beneficiary
  from vol_with_rates
  group by 1
)
select
  v.primary_taxonomy,
  v.t2,
  v.sequence_length,
  v.hcpcs_code,
  v.claim_count,
  v.total_paid,
  v.beneficiary_count,
  v.npi_count,
  v.claims_per_beneficiary,
  v.spend_per_beneficiary,
  s.avg_claims_per_beneficiary as hcpcs_avg_claims_per_beneficiary,
  s.stddev_claims_per_beneficiary as hcpcs_stddev_claims_per_beneficiary,
  s.avg_spend_per_beneficiary as hcpcs_avg_spend_per_beneficiary,
  s.stddev_spend_per_beneficiary as hcpcs_stddev_spend_per_beneficiary,
  safe_divide(v.claims_per_beneficiary, s.avg_claims_per_beneficiary) as claims_index,
  safe_divide(v.spend_per_beneficiary, s.avg_spend_per_beneficiary) as spend_index,
  safe_divide(v.claims_per_beneficiary - s.avg_claims_per_beneficiary, nullif(s.stddev_claims_per_beneficiary, 0)) as claims_z_score,
  safe_divide(v.spend_per_beneficiary - s.avg_spend_per_beneficiary, nullif(s.stddev_spend_per_beneficiary, 0)) as spend_z_score,
  (abs(safe_divide(v.claims_per_beneficiary - s.avg_claims_per_beneficiary, nullif(s.stddev_claims_per_beneficiary, 0))) > 2
   or abs(safe_divide(v.spend_per_beneficiary - s.avg_spend_per_beneficiary, nullif(s.stddev_spend_per_beneficiary, 0))) > 2) as is_outlier
from vol_with_rates v
left join hcpcs_stats s on s.hcpcs_code = v.hcpcs_code
order by v.sequence_length, v.claim_count desc
