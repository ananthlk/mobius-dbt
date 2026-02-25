{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 2: Location validation (address/site-level checks). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('address_validation_fl') }}
