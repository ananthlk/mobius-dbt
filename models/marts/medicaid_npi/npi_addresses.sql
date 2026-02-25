{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- NPI addresses from NPPES for PML-enrolled (FL) providers.
-- Step 1.5 of FL Medicaid NPI validation pipeline. Feeds into doge_validation_granular for address matching.

with pml_npis as (
  select distinct npi
  from {{ ref('stg_pml_run') }}
  where npi is not null and trim(npi) != ''
)
select
  n.npi,
  n.provider_first_line_business_practice_location_address as address_line_1,
  n.provider_second_line_business_practice_location_address as address_line_2,
  n.provider_business_practice_location_address_city_name as city,
  n.provider_business_practice_location_address_state_name as state,
  n.provider_business_practice_location_address_postal_code as zip
from {{ source('nppes_public', 'npi_optimized') }} n
inner join pml_npis p on p.npi = n.npi
