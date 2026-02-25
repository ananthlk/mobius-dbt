{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- B0 Sub-org = one facility + one address. One address per sub-org (suite/line can differ).
-- Each row is a (facility_npi, normalized_address) with sub_org_id. See B0 plan.

with facility as (
  select
    facility_npi,
    practice_line_1,
    practice_city,
    practice_state,
    practice_zip_digits,
    mailing_line_1,
    mailing_city,
    mailing_state,
    mailing_zip_digits
  from {{ ref('b0_facility_master_fl') }}
),
-- Normalized address: line1 + city + state + zip digits (ZIP5 minimum)
norm_practice as (
  select
    facility_npi,
    'practice' as address_type,
    upper(trim(regexp_replace(
      concat(
        coalesce(trim(practice_line_1), ''),
        ' ',
        coalesce(trim(practice_city), ''),
        ' ',
        coalesce(trim(practice_state), ''),
        ' ',
        case when length(practice_zip_digits) >= 5 then substr(practice_zip_digits, 1, 5) else coalesce(practice_zip_digits, '') end
      ),
      r'\s+', ' '
    ))) as address_normalized,
    practice_line_1 as address_line_1,
    practice_city as city,
    practice_state as state,
    case when length(practice_zip_digits) >= 5 then substr(practice_zip_digits, 1, 5) else null end as zip5,
    case when length(practice_zip_digits) >= 9 then substr(practice_zip_digits, 1, 9) else null end as zip9
  from facility
  where practice_line_1 is not null and trim(practice_line_1) != ''
),
norm_mailing as (
  select
    facility_npi,
    'mailing' as address_type,
    upper(trim(regexp_replace(
      concat(
        coalesce(trim(mailing_line_1), ''),
        ' ',
        coalesce(trim(mailing_city), ''),
        ' ',
        coalesce(trim(mailing_state), ''),
        ' ',
        case when length(mailing_zip_digits) >= 5 then substr(mailing_zip_digits, 1, 5) else coalesce(mailing_zip_digits, '') end
      ),
      r'\s+', ' '
    ))) as address_normalized,
    mailing_line_1 as address_line_1,
    mailing_city as city,
    mailing_state as state,
    case when length(mailing_zip_digits) >= 5 then substr(mailing_zip_digits, 1, 5) else null end as zip5,
    case when length(mailing_zip_digits) >= 9 then substr(mailing_zip_digits, 1, 9) else null end as zip9
  from facility
  where mailing_line_1 is not null and trim(mailing_line_1) != ''
),
combined as (
  select * from norm_practice
  union all
  select * from norm_mailing
),
-- Dedupe: same facility + same normalized address = one sub-org (keep first)
with_id as (
  select
    facility_npi,
    address_type,
    address_normalized,
    address_line_1,
    city,
    state,
    zip5,
    zip9,
    cast(farm_fingerprint(concat(facility_npi, '|', address_normalized)) as string) as sub_org_id
  from combined
  qualify row_number() over (partition by facility_npi, address_normalized order by address_type) = 1
)
select
  sub_org_id,
  facility_npi as org_id,
  address_type,
  address_normalized,
  address_line_1,
  city,
  state,
  zip5,
  zip9
from with_id
