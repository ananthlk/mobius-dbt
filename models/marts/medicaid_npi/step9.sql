{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 9: Error report with recommendations (main). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('provider_readiness_report') }}
