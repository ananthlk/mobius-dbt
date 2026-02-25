{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- B0 Sub-org members: one row per (sub_org_id, npi). Prefer strong match; include partial.
-- NPIs can be in multiple sub-orgs. See B0 plan.

select
  sub_org_id,
  org_id,
  npi,
  match_type
from {{ ref('b0_address_propensity_fl') }}
where match_type in ('strong', 'partial')
