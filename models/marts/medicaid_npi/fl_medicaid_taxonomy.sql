{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- FL Medicaid Taxonomy Master List. Valid taxonomy codes for claims.
-- Source: stg_tml_run (unified landing filtered by state_code, product). See docs/MEDICAID_NPI_UNIFIED_LANDING.md.

select distinct trim(cast(taxonomy_code as string)) as taxonomy_code
from {{ ref('stg_tml_run') }}
where taxonomy_code is not null and trim(cast(taxonomy_code as string)) != ''
