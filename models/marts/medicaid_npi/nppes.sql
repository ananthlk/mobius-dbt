{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- NPPES with practice_state for state-scoped runs. No filter; use nppes_run for current state.
-- Source: bigquery-public-data.nppes.npi_optimized.

select
  cast(npi as string) as npi,
  coalesce(trim(cast(provider_business_practice_location_address_state_name as string)), '') as practice_state,
  entity_type_code,
  provider_organization_name_legal_business_name,
  provider_last_name_legal_name,
  provider_first_name,
  provider_first_line_business_practice_location_address,
  provider_second_line_business_practice_location_address,
  provider_business_practice_location_address_city_name,
  provider_business_practice_location_address_state_name,
  provider_business_practice_location_address_postal_code,
  provider_first_line_business_mailing_address,
  provider_second_line_business_mailing_address,
  provider_business_mailing_address_city_name,
  provider_business_mailing_address_state_name,
  provider_business_mailing_address_postal_code,
  healthcare_provider_taxonomy_code_1,
  healthcare_provider_taxonomy_code_2,
  healthcare_provider_taxonomy_code_3,
  healthcare_provider_taxonomy_code_4,
  healthcare_provider_taxonomy_code_5,
  healthcare_provider_taxonomy_code_6,
  healthcare_provider_taxonomy_code_7,
  healthcare_provider_taxonomy_code_8,
  healthcare_provider_taxonomy_code_9,
  healthcare_provider_taxonomy_code_10,
  healthcare_provider_taxonomy_code_11,
  healthcare_provider_taxonomy_code_12,
  healthcare_provider_taxonomy_code_13,
  healthcare_provider_taxonomy_code_14,
  healthcare_provider_taxonomy_code_15,
  cast(null as string) as provider_credential_text
from {{ source('nppes_public', 'npi_optimized') }}
where npi is not null
