{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Analysis 6: Danger opportunities. Provider bills code Z; cohort with same taxonomy rarely bills Z.
-- "Review billing of Z."

with indexed as (
  select primary_taxonomy, t2, hcpcs_code, is_outlier, claims_z_score, spend_z_score
  from {{ ref('taxonomy_hcpcs_volume_indexed_fl') }}
  where is_outlier
),
unpiv as (
  select npi, taxonomy_code, is_primary from {{ ref('nppes_taxonomies_unpivoted_fl') }}
),
one_t2_per_npi as (
  select npi, taxonomy_code as t2,
    row_number() over (partition by npi order by taxonomy_code) as rn
  from unpiv where not is_primary
),
npi_t1_t2 as (
  select p.npi, p.taxonomy_code as t1, u.t2
  from unpiv p
  left join one_t2_per_npi u on u.npi = p.npi and u.rn = 1
  where p.is_primary
),
billing as (
  select servicing_npi as npi, hcpcs_code, sum(claim_count) as claim_count, sum(total_paid) as total_paid
  from {{ ref('billing_servicing_pairs_fl') }}
  group by 1, 2
)
select
  b.npi,
  b.hcpcs_code,
  b.claim_count,
  b.total_paid,
  t.t1 as primary_taxonomy,
  t.t2,
  i.claims_z_score,
  i.spend_z_score
from billing b
join npi_t1_t2 t on t.npi = b.npi
join indexed i
  on i.primary_taxonomy = t.t1
  and ((i.t2 is null and t.t2 is null) or (i.t2 = t.t2))
  and i.hcpcs_code = b.hcpcs_code
order by b.npi, b.total_paid desc
