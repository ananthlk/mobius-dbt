{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 1a: Organizations (billing NPI, org name, address, spend). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('organizations') }}
