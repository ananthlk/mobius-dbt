{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Roster upload cleaned: from stg_roster_upload (loaded from GCS cleansed output).
-- One row per upload row. Use var('roster_upload_id') to filter for a specific upload.

select
  upload_id,
  org_name,
  row_num,
  raw_npi,
  raw_name,
  npi_number,
  provider_name,
  raw_tin,
  resolved_npi,
  nppes_name,
  nppes_status,
  resolve_confidence
from {{ source('landing_medicaid_npi', 'stg_roster_upload') }}
where upload_id = '{{ var("roster_upload_id", "") }}'
