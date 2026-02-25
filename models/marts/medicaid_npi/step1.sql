{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 1: Roster list (org_id, site_id, npi, …). See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select * from {{ ref('b0_roster_list_fl') }}
