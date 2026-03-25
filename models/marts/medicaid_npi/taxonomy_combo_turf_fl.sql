{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Analysis 2: TURF-style taxonomy combos. Sequential: T1 (primary) -> T2 -> T3 -> T4 -> T5.
-- At each level: given previous taxonomy set, what's the next most common? Depth 5 to inspect tail.
-- Includes credential mix (from NPPES provider_credential_text) per primary taxonomy.
-- Input: nppes_taxonomies_unpivoted_fl, nppes_fl.

with unpiv as (
  select npi, taxonomy_code, is_primary
  from {{ ref('nppes_taxonomies_unpivoted_fl') }}
),
cohort_size as (
  select count(distinct npi) as n from unpiv
),
primaries as (
  select npi, taxonomy_code as t1
  from unpiv where is_primary
),
npi_tax as (
  select npi, taxonomy_code from unpiv
),

-- Level 1: primary taxonomy counts
l1 as (
  select t1, count(distinct npi) as npi_count
  from primaries group by 1
),

-- Level 2: (t1, t2) where npi has both, t1 != t2
l2_raw as (
  select p.t1, t.taxonomy_code as t2, p.npi
  from primaries p
  inner join npi_tax t on t.npi = p.npi and t.taxonomy_code != p.t1
),
l2 as (
  select t1, t2, count(distinct npi) as npi_count
  from l2_raw group by 1, 2
),

-- Level 3: (t1, t2, t3) where npi has all three distinct
l3_raw as (
  select a.t1, a.t2, t.taxonomy_code as t3, a.npi
  from l2_raw a
  inner join npi_tax t on t.npi = a.npi
    and t.taxonomy_code not in (a.t1, a.t2)
),
l3 as (
  select t1, t2, t3, count(distinct npi) as npi_count
  from l3_raw group by 1, 2, 3
),

-- Level 4: (t1, t2, t3, t4)
l4_raw as (
  select a.t1, a.t2, a.t3, t.taxonomy_code as t4, a.npi
  from l3_raw a
  inner join npi_tax t on t.npi = a.npi
    and t.taxonomy_code not in (a.t1, a.t2, a.t3)
),
l4 as (
  select t1, t2, t3, t4, count(distinct npi) as npi_count
  from l4_raw group by 1, 2, 3, 4
),

-- Level 5: (t1, t2, t3, t4, t5)
l5_raw as (
  select a.t1, a.t2, a.t3, a.t4, t.taxonomy_code as t5, a.npi
  from l4_raw a
  inner join npi_tax t on t.npi = a.npi
    and t.taxonomy_code not in (a.t1, a.t2, a.t3, a.t4)
),
l5 as (
  select t1, t2, t3, t4, t5, count(distinct npi) as npi_count
  from l5_raw group by 1, 2, 3, 4, 5
),

-- Credential mix per primary taxonomy (from NPPES)
credential_by_t1 as (
  select
    p.t1,
    coalesce(nullif(trim(npp.provider_credential_text), ''), 'Unknown') as credential,
    count(distinct p.npi) as cred_npi_count
  from primaries p
  inner join {{ ref('nppes_run') }} npp on npp.npi = p.npi
  group by 1, 2
),
credential_ranked as (
  select t1, credential, cred_npi_count,
    sum(cred_npi_count) over (partition by t1) as t1_total,
    row_number() over (partition by t1 order by cred_npi_count desc) as rn
  from credential_by_t1
),
credential_mix as (
  select t1,
    string_agg(
      credential || ' (' || round(safe_divide(cred_npi_count, t1_total) * 100, 1) || '%)',
      ', ' order by cred_npi_count desc
    ) as top_credentials
  from credential_ranked
  where rn <= 5
  group by t1
),

-- Union all levels with sequence_length and pct_of_cohort
all_levels as (
  select t1, cast(null as string) as t2, cast(null as string) as t3, cast(null as string) as t4, cast(null as string) as t5,
    1 as sequence_length, npi_count, safe_divide(npi_count, (select n from cohort_size)) * 100 as pct_of_cohort
  from l1
  union all
  select t1, t2, cast(null as string), cast(null as string), cast(null as string),
    2, npi_count, safe_divide(npi_count, (select n from cohort_size)) * 100
  from l2
  union all
  select t1, t2, t3, cast(null as string), cast(null as string),
    3, npi_count, safe_divide(npi_count, (select n from cohort_size)) * 100
  from l3
  union all
  select t1, t2, t3, t4, cast(null as string),
    4, npi_count, safe_divide(npi_count, (select n from cohort_size)) * 100
  from l4
  union all
  select t1, t2, t3, t4, t5,
    5, npi_count, safe_divide(npi_count, (select n from cohort_size)) * 100
  from l5
)
select
  a.t1 as primary_taxonomy,
  a.t2, a.t3, a.t4, a.t5,
  a.sequence_length,
  a.npi_count,
  a.pct_of_cohort,
  safe_divide(a.npi_count, l1.npi_count) * 100 as pct_of_t1,
  (select n from cohort_size) as cohort_size,
  cm.top_credentials
from all_levels a
left join l1 on l1.t1 = a.t1
left join credential_mix cm on cm.t1 = a.t1
order by a.sequence_length, a.npi_count desc
