{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 3: NPI validation (in_nppes, enrollment-related flags). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('provider_readiness') }}
