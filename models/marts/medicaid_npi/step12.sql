{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 12: Missed/billing opportunities (main). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('provider_missed_opportunities_fl') }}
