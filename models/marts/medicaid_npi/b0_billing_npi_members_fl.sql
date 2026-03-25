{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- B0 Billing NPI → member (servicing) NPIs. We do not have TIN; use billing NPI as group.
-- One row per (billing_npi, servicing_npi). Union with address-based structure for roster list.

select
  billing_npi,
  servicing_npi as member_npi
from {{ ref('billing_servicing_pairs_run') }}
group by billing_npi, servicing_npi
