{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- National NUCC Healthcare Provider Taxonomy code set.
-- Source: landing_medicaid_npi.stg_nucc_taxonomy. Load via scripts/load_nucc_to_landing.py
-- from seeds/nucc_taxonomy_seed.csv or full nucc_taxonomy_250.csv. NUCC publishes twice yearly (Jan, July).

select
  trim(cast(taxonomy_code as string)) as taxonomy_code,
  trim(cast(taxonomy_description as string)) as taxonomy_description
from {{ source('landing_medicaid_npi', 'stg_nucc_taxonomy') }}
where taxonomy_code is not null and trim(cast(taxonomy_code as string)) != ''
