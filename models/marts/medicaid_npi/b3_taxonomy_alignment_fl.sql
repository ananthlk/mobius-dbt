{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- B3 Taxonomy alignment: all NPPES taxonomies vs FL allowed set (TML).
-- One row per NPI. Flags: at_least_one_viable_in_fl, no_viable_in_fl, counts.
-- See docs/B3_TAXONOMY_AND_FINAL_RULE.md. Brought together with B1 later.

with fl_allowed as (
  select distinct trim(cast(taxonomy_code as string)) as taxonomy_code
  from {{ ref('fl_medicaid_taxonomy') }}
  where taxonomy_code is not null and trim(cast(taxonomy_code as string)) != ''
),
nppes_tax as (
  select
    npi,
    trim(cast(taxonomy_code as string)) as taxonomy_code,
    is_primary
  from {{ ref('nppes_taxonomies_unpivoted_fl') }}
),
npi_counts as (
  select
    n.npi,
    count(distinct n.taxonomy_code) as b3_nppes_taxonomy_count,
    count(distinct case when f.taxonomy_code is not null then n.taxonomy_code end) as b3_fl_allowed_count
  from nppes_tax n
  left join fl_allowed f on f.taxonomy_code = n.taxonomy_code
  group by n.npi
)
select
  npi,
  b3_nppes_taxonomy_count,
  b3_fl_allowed_count,
  (b3_fl_allowed_count >= 1) as b3_at_least_one_viable_in_fl,
  (b3_nppes_taxonomy_count >= 1 and b3_fl_allowed_count = 0) as b3_no_viable_in_fl,
  case
    when b3_nppes_taxonomy_count = 0 then 'no_nppes_taxonomy'
    when b3_fl_allowed_count >= 1 then 'pass'
    when b3_fl_allowed_count = 0 then 'no_viable_in_fl'
    else 'pass'
  end as b3_status
from npi_counts
