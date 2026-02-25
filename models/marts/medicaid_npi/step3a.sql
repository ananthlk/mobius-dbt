{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 3a: NPPES state cohort. See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('nppes_fl') }}
