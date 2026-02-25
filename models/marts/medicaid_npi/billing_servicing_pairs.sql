{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Billing → servicing pairs with volume from DOGE. Source stg_doge should expose:
-- billing_npi, servicing_npi, claim_count, total_paid, beneficiary_count, hcpcs_code (or raw names mapped in landing).

select
  cast(billing_npi as string) as billing_npi,
  cast(servicing_npi as string) as servicing_npi,
  coalesce(claim_count, 1) as claim_count,
  coalesce(total_paid, 0) as total_paid,
  coalesce(beneficiary_count, 0) as beneficiary_count,
  hcpcs_code
from {{ source('landing_medicaid_npi', 'stg_doge') }}
where billing_npi is not null and servicing_npi is not null
