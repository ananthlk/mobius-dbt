{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Analysis 3: Taxonomy → HCPCS volume at TURF combo level.
-- For each (primary_taxonomy, t2) and hcpcs_code: claim_count, total_paid, npi_count.
-- Depth 2 (T1 and T1+T2) to start. Feeds missed/danger opportunity detection.

with unpiv as (
  select npi, taxonomy_code, is_primary
  from {{ ref('nppes_taxonomies_unpivoted_fl') }}
),
primaries as (
  select npi, taxonomy_code as t1
  from unpiv where is_primary
),
npi_tax as (
  select npi, taxonomy_code from unpiv
),
-- Level 2 cohort: NPIs with t1 and t2
l2_cohort as (
  select p.t1, t.taxonomy_code as t2, p.npi
  from primaries p
  inner join npi_tax t on t.npi = p.npi and t.taxonomy_code != p.t1
),
billing as (
  select
    servicing_npi as npi,
    hcpcs_code,
    sum(claim_count) as claim_count,
    sum(total_paid) as total_paid,
    sum(beneficiary_count) as beneficiary_count
  from {{ ref('billing_servicing_pairs_run') }}
  group by 1, 2
),

-- Level 1: (t1, hcpcs) volume
vol_t1 as (
  select
    p.t1 as primary_taxonomy,
    cast(null as string) as t2,
    1 as sequence_length,
    b.hcpcs_code,
    sum(b.claim_count) as claim_count,
    sum(b.total_paid) as total_paid,
    sum(b.beneficiary_count) as beneficiary_count,
    count(distinct p.npi) as npi_count
  from primaries p
  inner join billing b on b.npi = p.npi
  group by 1, 2, 3, 4
),

-- Level 2: (t1, t2, hcpcs) volume
vol_t1_t2 as (
  select
    c.t1 as primary_taxonomy,
    c.t2,
    2 as sequence_length,
    b.hcpcs_code,
    sum(b.claim_count) as claim_count,
    sum(b.total_paid) as total_paid,
    sum(b.beneficiary_count) as beneficiary_count,
    count(distinct c.npi) as npi_count
  from l2_cohort c
  inner join billing b on b.npi = c.npi
  group by 1, 2, 3, 4
)

select * from vol_t1
union all
select * from vol_t1_t2
order by sequence_length, claim_count desc
