{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- FL Medicaid provider IDs from PML (Provider Master List).
-- Source: stg_pml_run (unified landing filtered by state_code, product). See docs/MEDICAID_NPI_UNIFIED_LANDING.md.

select
  medicaid_provider_id,
  npi,
  provider_name,
  provider_type,
  specialty_type,
  address_line_1,
  city,
  state,
  zip,
  zip_plus_4,
  contract_effective_date,
  contract_end_date,
  status
from {{ ref('stg_pml_run') }}
