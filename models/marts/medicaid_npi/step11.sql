{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 11: Billing rate validation. Stub until fee schedule/rate data in landing. See docs/FL_MEDICAID_NPI_STEP_NAMING.md.
select
  cast(null as string) as npi,
  cast(null as string) as billing_npi,
  cast(null as string) as hcpcs_code,
  cast(null as float64) as paid_amount,
  cast(null as float64) as expected_rate,
  cast(null as string) as rate_validation_status
from (select 1) t
where false
