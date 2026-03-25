{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Distinct site-level details per org with reasoning. One row per (org_npi, site address).
-- site_source: base = org address; additional = servicing NPI practice address from DOGE.
-- site_reason: human-readable explanation of why this site was added.
-- See docs/PROVIDER_ROSTER_CREDENTIALING_PIPELINE.md.

select distinct
  org_npi,
  org_name,
  site_address_line_1,
  site_city,
  site_state,
  site_zip,
  site_zip9,
  site_source,
  case
    when site_source = 'base'
    then 'Org practice address (entity type 1 or 2, NPPES or PML).'
    when site_source = 'additional'
    then 'Practice address of servicing NPI(s) who billed under this org in DOGE (from NPPES or PML).'
    else 'Unknown'
  end as site_reason
from {{ ref('bh_roster') }}
