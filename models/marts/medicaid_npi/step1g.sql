{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 1g: Billing NPI → member NPIs. See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('b0_billing_npi_members_fl') }}
