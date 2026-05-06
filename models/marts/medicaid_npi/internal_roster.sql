{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Internal roster: from roster_upload_cleaned with resolved NPI preferred.
-- One row per (upload_id, org_name, npi). npi = coalesce(resolved_npi, npi_number).

select
  upload_id,
  org_name,
  coalesce(nullif(cast(resolved_npi as string), ''), nullif(trim(npi_number), '')) as npi,
  provider_name,
  resolve_confidence
from {{ ref('roster_upload_cleaned') }}
where coalesce(nullif(cast(resolved_npi as string), ''), nullif(trim(npi_number), '')) != ''
