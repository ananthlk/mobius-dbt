{{
  config(
    materialized='view',
    schema=env_var('BQ_LANDING_MEDICAID_DATASET', 'landing_medicaid_npi_dev'),
  )
}}

-- stg_doge: Mobius schema view over medicaid-provider-spending (HHS DOGE).
-- Maps HHS column names to our expected schema for billing_patterns, organizations, etc.
-- Raw table has: BILLING_PROVIDER_NPI_NUM, SERVICING_PROVIDER_NPI_NUM, HCPCS_CODE,
-- CLAIM_FROM_MONTH, TOTAL_UNIQUE_BENEFICIARIES, TOTAL_CLAIMS, TOTAL_PAID.
-- billing_tin, servicing_tin, state not in source → NULL.

select
  BILLING_PROVIDER_NPI_NUM as npi,
  BILLING_PROVIDER_NPI_NUM as billing_npi,
  SERVICING_PROVIDER_NPI_NUM as servicing_npi,
  cast(null as string) as billing_tin,
  cast(null as string) as servicing_tin,
  HCPCS_CODE as hcpcs_code,
  CLAIM_FROM_MONTH as period_month,
  TOTAL_UNIQUE_BENEFICIARIES as beneficiary_count,
  TOTAL_CLAIMS as claim_count,
  TOTAL_PAID as total_paid,
  cast(null as string) as state
from {{ source('landing_medicaid_npi', 'medicaid_provider_spending') }}
