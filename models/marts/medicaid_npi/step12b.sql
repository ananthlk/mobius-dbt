{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 12b: Danger opportunities (review billing). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('provider_danger_opportunities_fl') }}
