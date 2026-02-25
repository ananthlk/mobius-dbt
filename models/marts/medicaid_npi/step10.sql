{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 10: Reserved. Placeholder view. See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select
  cast(null as string) as reserved_npi,
  cast(null as date) as reserved_date
from (select 1) t
where false
