{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 6: Taxonomy validation output (main). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('b3_taxonomy_alignment_fl') }}
