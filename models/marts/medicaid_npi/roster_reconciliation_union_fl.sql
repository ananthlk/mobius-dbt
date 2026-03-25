{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Union of all NPIs from reconciliation (in_both + external_only + internal_only).
-- For PML/NPPES validation on the full roster.

select
  upload_id,
  org_name,
  npi,
  reconciliation_status
from {{ ref('roster_reconciliation_fl') }}
