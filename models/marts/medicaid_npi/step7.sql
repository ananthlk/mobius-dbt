{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 7: Billing code validation (main). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('taxonomy_validation_fl') }}
