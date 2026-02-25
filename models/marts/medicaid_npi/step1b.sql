{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 1b: Billing–servicing pairs (state-scoped). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('billing_servicing_pairs_fl') }}
