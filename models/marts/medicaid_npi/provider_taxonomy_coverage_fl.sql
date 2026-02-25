{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Analysis 4: Provider taxonomy coverage score vs cohort prevalence.
-- Low coverage = data gaps or niche; high = well-aligned.

with prevalence as (
  select taxonomy_code, pct
  from {{ ref('taxonomy_prevalence_fl') }}
),
provider_tax as (
  select npi, taxonomy_code
  from {{ ref('nppes_taxonomies_unpivoted_fl') }}
),
-- Weighted sum of prevalence for taxonomies provider has
provider_score as (
  select
    p.npi,
    count(distinct p.taxonomy_code) as taxonomy_count,
    sum(coalesce(pr.pct, 0)) as prevalence_sum
  from provider_tax p
  left join prevalence pr on pr.taxonomy_code = p.taxonomy_code
  group by 1
),
cohort_max as (
  select max(prevalence_sum) as max_sum from provider_score
),
-- Top prevalent taxonomies provider lacks
top_prevalent as (
  select taxonomy_code, pct
  from (select taxonomy_code, pct, row_number() over (order by pct desc) as rn from prevalence) r
  where r.rn <= 30
),
provider_has as (
  select npi, taxonomy_code from provider_tax
),
missing_raw as (
  select
    p.npi,
    tp.taxonomy_code,
    tp.pct
  from (select distinct npi from provider_tax) p
  cross join top_prevalent tp
  where not exists (
    select 1 from provider_has h where h.npi = p.npi and h.taxonomy_code = tp.taxonomy_code
  )
),
missing as (
  select
    npi,
    array_agg(taxonomy_code order by pct desc limit 5) as missing_high_prevalence
  from missing_raw
  group by 1
)
select
  s.npi,
  s.taxonomy_count,
  round(least(100, greatest(0, safe_divide(s.prevalence_sum, c.max_sum) * 100)), 1) as coverage_score,
  m.missing_high_prevalence
from provider_score s
cross join cohort_max c
left join missing m on m.npi = s.npi
