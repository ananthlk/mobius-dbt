{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 6c: Taxonomy validation (C1–C4, D, F). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('taxonomy_validation_fl') }}
