{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 4a: NPI addresses (practice/mailing, B1 fields). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('npi_addresses_fl') }}
