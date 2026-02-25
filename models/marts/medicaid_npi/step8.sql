{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 8: Comprehensive check (NPI + Medicaid ID + taxonomy + location). Single read head = B6. See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('b6_integrated_report_fl') }}
