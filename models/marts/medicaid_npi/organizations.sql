{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Organizations: distinct billing NPIs from DOGE with NPPES org name, address, and aggregate spend.
-- Step 1.1 of FL Medicaid NPI validation pipeline. Source: billing_servicing_pairs_fl (FL scope).

with doge_billing as (
  select
    billing_npi,
    sum(total_paid) as aggregate_spend_2024,
    sum(claim_count) as claim_count_2024,
    sum(beneficiary_count) as beneficiary_count_2024
  from {{ ref('billing_servicing_pairs_fl') }}
  where billing_npi is not null and trim(billing_npi) != ''
  group by 1
),
nppes as (
  select
    npi,
    entity_type_code,
    coalesce(
      provider_organization_name_legal_business_name,
      concat(provider_last_name_legal_name, ', ', provider_first_name)
    ) as org_name,
    provider_first_line_business_practice_location_address as address_line_1,
    provider_second_line_business_practice_location_address as address_line_2,
    provider_business_practice_location_address_city_name as city,
    provider_business_practice_location_address_state_name as state,
    provider_business_practice_location_address_postal_code as zip
  from {{ source('nppes_public', 'npi_optimized') }}
)
select
  d.billing_npi,
  n.entity_type_code,
  coalesce(n.org_name, 'Unknown') as org_name,
  n.address_line_1,
  n.address_line_2,
  n.city,
  n.state,
  n.zip,
  d.aggregate_spend_2024,
  d.claim_count_2024,
  d.beneficiary_count_2024
from doge_billing d
left join nppes n on n.npi = d.billing_npi
