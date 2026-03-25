{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 6: Taxonomy alignment (B3) per NPI — NPPES taxonomies vs FL TML.
-- Self-sufficient with npi_provider_name and step_explanation. See docs/FL_MEDICAID_NPI_STEP_OUTPUTS.md.

with base as (
  select * from {{ ref('b3_taxonomy_alignment_fl') }}
),
npi_names as (
  select
    cast(npi as string) as npi,
    coalesce(
      nullif(trim(coalesce(provider_organization_name_legal_business_name, '')), ''),
      nullif(trim(concat(coalesce(trim(provider_last_name_legal_name), ''), ', ', coalesce(trim(provider_first_name), ''))), ','),
      'Unknown'
    ) as npi_provider_name
  from {{ ref('nppes_run') }}
)
select
  b.npi,
  coalesce(n.npi_provider_name, 'Unknown') as npi_provider_name,
  b.b3_nppes_taxonomy_count,
  b.b3_fl_allowed_count,
  b.b3_at_least_one_viable_in_fl,
  b.b3_no_viable_in_fl,
  b.b3_status,
  'Taxonomy: ' || b.b3_status || '. ' || cast(b.b3_fl_allowed_count as string) || ' FL-allowed of ' || cast(b.b3_nppes_taxonomy_count as string) || ' NPPES taxonomies.' as step_explanation
from base b
left join npi_names n on n.npi = b.npi
