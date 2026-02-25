{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 6a: State Medicaid taxonomy (TML). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('fl_medicaid_taxonomy') }}
