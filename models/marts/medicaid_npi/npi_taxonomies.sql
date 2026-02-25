{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- NPI → taxonomy mapping from NPPES, restricted to TML-valid codes and PML-enrolled (FL) NPIs.
-- Step 1.4 of FL Medicaid NPI validation pipeline.

with nppes_tax as (
  select
    npi,
    taxonomy_code
  from {{ source('nppes_public', 'npi_optimized') }},
  unnest([
    healthcare_provider_taxonomy_code_1,
    healthcare_provider_taxonomy_code_2,
    healthcare_provider_taxonomy_code_3,
    healthcare_provider_taxonomy_code_4,
    healthcare_provider_taxonomy_code_5,
    healthcare_provider_taxonomy_code_6,
    healthcare_provider_taxonomy_code_7,
    healthcare_provider_taxonomy_code_8,
    healthcare_provider_taxonomy_code_9,
    healthcare_provider_taxonomy_code_10,
    healthcare_provider_taxonomy_code_11,
    healthcare_provider_taxonomy_code_12,
    healthcare_provider_taxonomy_code_13,
    healthcare_provider_taxonomy_code_14,
    healthcare_provider_taxonomy_code_15
  ]) as taxonomy_code
  where taxonomy_code is not null and trim(taxonomy_code) != ''
),
tml_valid as (
  select taxonomy_code
  from {{ ref('stg_tml_run') }}
  where taxonomy_code is not null and trim(taxonomy_code) != ''
),
pml_npis as (
  select distinct npi
  from {{ ref('stg_pml_run') }}
  where npi is not null and trim(npi) != ''
)
select distinct
  t.npi,
  t.taxonomy_code
from nppes_tax t
inner join tml_valid v on v.taxonomy_code = t.taxonomy_code
inner join pml_npis p on p.npi = t.npi
