{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Taxonomy co-occurrence: for each taxonomy T, what % of providers with T are also credentialed as T2?
-- Data-driven recommendation engine: "30% of providers with taxonomy X are also credentialed as LCSW."
-- Mobius standard: no one-size-fits-all; recommendations vary by prevalence in FL PML data.

with pml_detail as (
  select
    cast(npi as string) as npi,
    trim(cast(taxonomy_code as string)) as taxonomy_code
  from {{ source('landing_medicaid_npi', 'stg_pml') }}
  where npi is not null
    and taxonomy_code is not null
    and trim(cast(taxonomy_code as string)) != ''
),

-- Distinct (npi, taxonomy) per provider
npi_taxonomies as (
  select distinct npi, taxonomy_code
  from pml_detail
),

-- Primary count: NPIs per taxonomy
primary_counts as (
  select
    taxonomy_code as primary_taxonomy,
    count(distinct npi) as npi_count_primary
  from npi_taxonomies
  group by 1
),

-- Pairs: same NPI has both T and T2 (T != T2)
cooccur_pairs as (
  select
    a.taxonomy_code as primary_taxonomy,
    b.taxonomy_code as cooccurring_taxonomy,
    count(distinct a.npi) as npi_count_both
  from npi_taxonomies a
  inner join npi_taxonomies b
    on a.npi = b.npi
    and a.taxonomy_code != b.taxonomy_code
  group by 1, 2
),

-- Join to primary counts, compute pct, rank
with_pct as (
  select
    c.primary_taxonomy,
    c.cooccurring_taxonomy,
    p.npi_count_primary,
    c.npi_count_both,
    round(100.0 * c.npi_count_both / nullif(p.npi_count_primary, 0), 1) as pct,
    row_number() over (partition by c.primary_taxonomy order by c.npi_count_both desc) as rn
  from cooccur_pairs c
  inner join primary_counts p on c.primary_taxonomy = p.primary_taxonomy
  where c.npi_count_both >= 5
)

select
  primary_taxonomy,
  cooccurring_taxonomy,
  npi_count_primary,
  npi_count_both,
  pct
from with_pct
where rn <= 10
order by primary_taxonomy, pct desc
