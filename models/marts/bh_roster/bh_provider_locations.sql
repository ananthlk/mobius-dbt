{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Individual practitioners in FL (entity_type_code=1) with full NPPES address details.
-- Used by bh_roster to link BH orgs to servicing providers. No taxonomy filter.

select distinct
  cast(n.npi as string) as npi_str,
  coalesce(
    n.provider_organization_name_legal_business_name,
    concat(n.provider_last_name_legal_name, ', ', n.provider_first_name)
  ) as provider_name,
  trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) as provider_taxonomy_code,
  nucc.taxonomy_classification as provider_taxonomy_classification,
  t.classification as provider_bh_classification,
  t.bh_grouping as provider_bh_grouping,
  n.provider_first_line_business_practice_location_address as nppes_practice_line_1,
  n.provider_second_line_business_practice_location_address as nppes_practice_line_2,
  n.provider_business_practice_location_address_city_name as nppes_practice_city,
  n.provider_business_practice_location_address_state_name as nppes_practice_state,
  n.provider_business_practice_location_address_postal_code as nppes_practice_zip,
  substr(regexp_replace(coalesce(n.provider_business_practice_location_address_postal_code, ''), r'[^0-9]', ''), 1, 9) as zip9,
  n.provider_first_line_business_mailing_address as nppes_mailing_line_1,
  n.provider_business_mailing_address_city_name as nppes_mailing_city,
  n.provider_business_mailing_address_state_name as nppes_mailing_state,
  n.provider_business_mailing_address_postal_code as nppes_mailing_zip,
  lower(n.provider_first_line_business_practice_location_address) as addr1,
  regexp_replace(lower(n.provider_first_line_business_practice_location_address), r'[^a-z0-9]', '') as addr_clean_full,
  coalesce(t.classification, nucc.taxonomy_classification) as taxonomy_class
from {{ source('nppes_public', 'npi_raw') }} n
left join {{ ref('nucc_lookup') }} nucc
  on trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) = nucc.taxonomy_code
left join {{ ref('stg_bh_taxonomy_whitelist') }} t
  on n.healthcare_provider_taxonomy_code_1 = t.code
where n.entity_type_code = 1
  and (
    n.provider_business_practice_location_address_state_name = '{{ var("state_code", "FL") }}'
    or n.provider_license_number_state_code_1 = '{{ var("state_code", "FL") }}'
  )
