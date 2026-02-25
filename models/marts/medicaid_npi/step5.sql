{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 5: Medicaid ID validation (main). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('b4_npi_medicaid_status_fl') }}
