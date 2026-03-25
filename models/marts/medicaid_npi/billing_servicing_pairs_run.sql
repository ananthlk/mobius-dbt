{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Billing-servicing pairs where both NPIs are in current run state (nppes_run). No state bleed.
-- Replaces billing_servicing_pairs_fl; use var('state_code') to switch state.

with state_npis as (
  select npi from {{ ref('nppes_run') }}
)
select
  p.billing_npi,
  p.servicing_npi,
  p.claim_count,
  p.total_paid,
  p.beneficiary_count,
  p.hcpcs_code
from {{ ref('billing_servicing_pairs') }} p
inner join state_npis b on b.npi = p.billing_npi
inner join state_npis s on s.npi = p.servicing_npi
where p.billing_npi is not null and trim(p.billing_npi) != ''
  and p.servicing_npi is not null and trim(p.servicing_npi) != ''
