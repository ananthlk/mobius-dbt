{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 4b: Address validation (B1/B2/B3 flags). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('address_validation_fl') }}
