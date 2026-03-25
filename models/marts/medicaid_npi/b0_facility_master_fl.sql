{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- B0 Facility master list: entity type 2 (organization) OR facility-related taxonomy.
-- One row per facility NPI with practice/mailing address and ZIP+9 for sub-org definition.
-- See docs/B0_ROSTER_AND_ORG_STRUCTURE_PLAN.md.

with facility_tax as (
  select trim(cast(taxonomy_code as string)) as taxonomy_code
  from {{ ref('b0_facility_taxonomy_codes') }}
  where taxonomy_code is not null and trim(cast(taxonomy_code as string)) != ''
),
nppes_entity as (
  select
    cast(npi as string) as npi,
    cast(entity_type_code as string) as entity_type_code,
    provider_first_line_business_practice_location_address as practice_line_1,
    provider_business_practice_location_address_city_name as practice_city,
    provider_business_practice_location_address_state_name as practice_state,
    provider_business_practice_location_address_postal_code as practice_zip,
    provider_first_line_business_mailing_address as mailing_line_1,
    provider_business_mailing_address_city_name as mailing_city,
    provider_business_mailing_address_state_name as mailing_state,
    provider_business_mailing_address_postal_code as mailing_zip
  from {{ ref('nppes_run') }}
  where npi is not null
),
nppes_has_facility_tax as (
  select distinct n.npi
  from {{ ref('nppes_taxonomies_unpivoted_fl') }} n
  inner join facility_tax f on f.taxonomy_code = n.taxonomy_code
),
is_facility as (
  select
    n.npi,
    (n.entity_type_code = '2'
     or exists (select 1 from nppes_has_facility_tax t where t.npi = n.npi)) as is_facility
  from nppes_entity n
)
select
  n.npi as facility_npi,
  n.entity_type_code,
  n.practice_line_1,
  n.practice_city,
  n.practice_state,
  n.practice_zip,
  n.mailing_line_1,
  n.mailing_city,
  n.mailing_state,
  n.mailing_zip,
  regexp_replace(coalesce(n.practice_zip, ''), r'\D', '') as practice_zip_digits,
  regexp_replace(coalesce(n.mailing_zip, ''), r'\D', '') as mailing_zip_digits
from nppes_entity n
inner join is_facility f on f.npi = n.npi and f.is_facility
