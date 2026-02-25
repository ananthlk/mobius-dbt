{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 7b: Volume with indexing / outliers. See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('taxonomy_hcpcs_volume_indexed_fl') }}
