{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Per-NPI summary for report generation.
-- One row per (org_npi, servicing_npi): billable_yes, higher_revenue_potential_exists.
-- Aggregates from bh_roster_readiness (multi-taxonomy rows).
-- Report generation joins this when it needs NPI-level flags.

with readiness as (
  select * from {{ ref('bh_roster_readiness') }}
)

select
  org_npi,
  org_name,
  servicing_npi,
  servicing_provider_name,
  site_address_line_1,
  site_city,
  site_state,
  site_zip,
  logical_or(taxonomy_row_type = 'ready') as billable_yes,
  logical_or(higher_revenue_potential) as higher_revenue_potential_exists
from readiness
group by
  org_npi,
  org_name,
  servicing_npi,
  servicing_provider_name,
  site_address_line_1,
  site_city,
  site_state,
  site_zip
