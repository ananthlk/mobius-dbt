{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 2a: Site/location list (sub-org addresses). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('b0_sub_org_address_fl') }}
