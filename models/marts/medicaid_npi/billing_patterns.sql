{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
    tags=['expensive'],
  )
}}

-- Billing patterns from DOGE Medicaid Provider Spending. Filter by state in app when needed.
-- Source: landing_medicaid_npi.stg_doge (loaded from GCS raw/doge/).

select
  npi,
  billing_tin,
  servicing_tin,
  hcpcs_code,
  period_month,
  beneficiary_count,
  claim_count,
  total_paid,
  state
from {{ ref('stg_doge') }}
