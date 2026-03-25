{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Analysis 5: Missed opportunities. Provider lacks taxonomy T; T unlocks high-volume HCPCS.
-- "Add T to unlock X, Y." FL-only filter (from nppes_taxonomies_unpivoted_fl).

with provider_tax as (
  select npi, taxonomy_code from {{ ref('nppes_taxonomies_unpivoted_fl') }}
),
vol as (
  select primary_taxonomy, t2, hcpcs_code, claim_count, total_paid
  from {{ ref('taxonomy_hcpcs_volume_fl') }}
  where total_paid >= 10000
),
-- Taxonomies that unlock high-volume HCPCS (small set to join against)
vol_tax as (
  select distinct taxonomy_code from (
    select primary_taxonomy as taxonomy_code from vol
    union all
    select t2 from vol where t2 is not null
  )
),
unpiv as (
  select npi, taxonomy_code, is_primary from {{ ref('nppes_taxonomies_unpivoted_fl') }}
),
primaries as (
  select npi, taxonomy_code as t1 from unpiv where is_primary
),
-- All FL NPIs (from nppes_taxonomies_unpivoted_fl)
fl_npis as (
  select distinct npi from {{ ref('nppes_taxonomies_unpivoted_fl') }}
  where npi is not null and trim(npi) != ''
),
-- Provider lacks taxonomy T where T is in vol_tax; use anti-join
provider_lacks as (
  select p.npi, t.taxonomy_code as suggested_taxonomy
  from (select npi from fl_npis) p
  cross join vol_tax t
  left join provider_tax pt on pt.npi = p.npi and pt.taxonomy_code = t.taxonomy_code
  where pt.taxonomy_code is null
),
prevalence as (
  select taxonomy_code, pct from {{ ref('taxonomy_prevalence_fl') }}
)
select
  pl.npi,
  pl.suggested_taxonomy,
  pr.pct as suggested_taxonomy_prevalence_pct,
  v.hcpcs_code as unlock_hcpcs,
  v.claim_count,
  v.total_paid
from provider_lacks pl
join vol v on v.primary_taxonomy = pl.suggested_taxonomy or v.t2 = pl.suggested_taxonomy
left join prevalence pr on pr.taxonomy_code = pl.suggested_taxonomy
order by pl.npi, v.total_paid desc
