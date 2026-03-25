{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Analysis 1: Taxonomy prevalence in FL cohort. Uses nppes_taxonomies_unpivoted_fl.
-- Includes credential mix from NPPES (provider_credential_text) so results are interpretable.

with nppes_tax as (
  select distinct npi, taxonomy_code
  from {{ ref('nppes_taxonomies_unpivoted_fl') }}
),
cohort_size as (
  select count(distinct npi) as n
  from {{ ref('nppes_run') }}
),
prevalence as (
  select
    taxonomy_code,
    count(distinct npi) as npi_count
  from nppes_tax
  group by 1
),
credential_by_tax as (
  select
    t.taxonomy_code,
    coalesce(nullif(trim(npp.provider_credential_text), ''), 'Unknown') as credential,
    count(distinct t.npi) as cred_npi_count
  from nppes_tax t
  inner join {{ ref('nppes_run') }} npp on npp.npi = t.npi
  group by 1, 2
),
credential_ranked as (
  select
    taxonomy_code,
    credential,
    cred_npi_count,
    sum(cred_npi_count) over (partition by taxonomy_code) as tax_total,
    row_number() over (partition by taxonomy_code order by cred_npi_count desc) as rn
  from credential_by_tax
),
credential_mix as (
  select
    taxonomy_code,
    string_agg(
      credential || ' (' || round(safe_divide(cred_npi_count, tax_total) * 100, 1) || '%)',
      ', ' order by cred_npi_count desc
    ) as top_credentials
  from credential_ranked
  where rn <= 5
  group by 1
)
select
  p.taxonomy_code,
  p.npi_count,
  c.n as cohort_size,
  safe_divide(p.npi_count, c.n) * 100 as pct,
  row_number() over (order by p.npi_count desc) as rank,
  cm.top_credentials,
  cast(null as string) as taxonomy_description_fl_medicaid,  -- fl_medicaid_taxonomy has taxonomy_code only
  n.taxonomy_description as taxonomy_description_national
from prevalence p
cross join cohort_size c
left join credential_mix cm on cm.taxonomy_code = p.taxonomy_code
left join {{ ref('fl_medicaid_taxonomy') }} fl on fl.taxonomy_code = p.taxonomy_code
left join {{ ref('nucc_taxonomy') }} n on n.taxonomy_code = p.taxonomy_code
