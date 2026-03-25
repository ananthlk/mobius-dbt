{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- NPI addresses for FL cohort. Practice + mailing from NPPES; PML service location for B1.
-- Normalized strings for B2 (mailing vs practice), B3 (org outlier), B1 (NPPES vs PML).
-- PML columns: service_location_address_1, service_location_address_zip (map from AHCA CSV if needed).

-- B1: PML = source of truth for FL Medicaid. Address alignment only (service location ZIP+9).
-- Taxonomy alignment is B3. Final rule: NPI + Medicaid ID + taxonomy + service location (B1 + B3 + B4).
-- (1) Neither address null — severe. (2) ZIP+9 match — severe if not. (3) Same street = warning only.
-- PML table: address_line_1, city, state, zip, zip_plus_4. Var: use_pml_address.
with
{% if var('use_pml_address', true) %}
pml_raw as (
  select
    cast(npi as string) as npi,
    trim(coalesce(cast(address_line_1 as string), '')) as pml_line_1,
    upper(trim(coalesce(cast(city as string), ''))) as pml_city,
    upper(trim(coalesce(cast(state as string), ''))) as pml_state,
    regexp_replace(coalesce(cast(zip as string), ''), r'\D', '') as pml_zip,
    regexp_replace(coalesce(cast(zip_plus_4 as string), ''), r'\D', '') as pml_zip4
  from {{ ref('stg_pml_run') }}
  where npi is not null
  qualify row_number() over (partition by cast(npi as string) order by contract_effective_date desc nulls last) = 1
),
pml_addr as (
  select
    npi,
    pml_line_1,
    pml_city,
    pml_state,
    case when length(pml_zip) >= 5 then substr(pml_zip, 1, 5) else pml_zip end as pml_zip5,
    case when length(pml_zip) >= 4 then substr(pml_zip, 1, 4) else pml_zip end as pml_zip4,
    case when length(pml_zip) >= 9 then substr(pml_zip, 1, 9)
         when length(pml_zip) >= 5 and length(pml_zip4) >= 4 then substr(pml_zip, 1, 5) || substr(pml_zip4, 1, 4)
         else null end as pml_zip9
  from pml_raw
),
{% else %}
pml_addr as (
  select cast(null as string) as npi, cast(null as string) as pml_line_1, cast(null as string) as pml_city, cast(null as string) as pml_state, cast(null as string) as pml_zip5, cast(null as string) as pml_zip4, cast(null as string) as pml_zip9
  from (select 1) where 1=0
),
{% endif %}
nppes as (
  select
    npi,
    provider_first_line_business_practice_location_address as practice_line_1,
    provider_second_line_business_practice_location_address as practice_line_2,
    provider_business_practice_location_address_city_name as practice_city,
    provider_business_practice_location_address_state_name as practice_state,
    provider_business_practice_location_address_postal_code as practice_zip,
    provider_first_line_business_mailing_address as mailing_line_1,
    provider_second_line_business_mailing_address as mailing_line_2,
    provider_business_mailing_address_city_name as mailing_city,
    provider_business_mailing_address_state_name as mailing_state,
    provider_business_mailing_address_postal_code as mailing_zip
  from {{ ref('nppes_run') }}
  where npi is not null
),
with_pml as (
  select
    n.npi,
    n.practice_line_1,
    n.practice_line_2,
    n.practice_city,
    n.practice_state,
    n.practice_zip,
    n.mailing_line_1,
    n.mailing_line_2,
    n.mailing_city,
    n.mailing_state,
    n.mailing_zip,
    p.pml_line_1,
    p.pml_city,
    p.pml_state,
    p.pml_zip5,
    p.pml_zip4,
    p.pml_zip9
  from nppes n
  left join pml_addr p on p.npi = cast(n.npi as string)
),
normalized as (
  select
    npi,
    practice_line_1,
    practice_line_2,
    practice_city,
    practice_state,
    practice_zip,
    mailing_line_1,
    mailing_line_2,
    mailing_city,
    mailing_state,
    mailing_zip,
    pml_line_1,
    pml_city,
    pml_state,
    pml_zip5,
    pml_zip4,
    pml_zip9,
    upper(trim(regexp_replace(
      concat(
        coalesce(trim(practice_line_1), ''),
        ' ',
        coalesce(trim(practice_city), ''),
        ' ',
        coalesce(trim(practice_state), ''),
        ' ',
        coalesce(regexp_replace(practice_zip, r'\D', ''), '')
      ),
      r'\s+', ' '
    ))) as practice_normalized,
    upper(trim(regexp_replace(
      concat(
        coalesce(trim(mailing_line_1), ''),
        ' ',
        coalesce(trim(mailing_city), ''),
        ' ',
        coalesce(trim(mailing_state), ''),
        ' ',
        coalesce(regexp_replace(mailing_zip, r'\D', ''), '')
      ),
      r'\s+', ' '
    ))) as mailing_normalized,
    coalesce(regexp_replace(practice_zip, r'\D', ''), '') as nppes_zip_digits,
    upper(trim(coalesce(trim(practice_city), ''))) as practice_city_norm,
    upper(trim(coalesce(trim(practice_state), ''))) as practice_state_norm
  from with_pml
),
nppes_loc as (
  select
    npi,
    nppes_zip_digits,
    case when length(nppes_zip_digits) >= 5 then substr(nppes_zip_digits, 1, 5) else null end as nppes_zip5,
    case when length(nppes_zip_digits) >= 4 then substr(nppes_zip_digits, 1, 4) else null end as nppes_zip4,
    case when length(nppes_zip_digits) >= 9 then substr(nppes_zip_digits, 1, 9) else null end as nppes_zip9
  from normalized
),
nppes_street_norm as (
  select
    npi,
    upper(trim(regexp_replace(coalesce(trim(practice_line_1), ''), r'\s+', ' '))) as practice_street_norm,
    upper(trim(regexp_replace(coalesce(trim(pml_line_1), ''), r'\s+', ' '))) as pml_street_norm
  from normalized
)
select
  n.npi,
  n.practice_line_1,
  n.practice_line_2,
  n.practice_city,
  n.practice_state,
  n.practice_zip,
  n.mailing_line_1,
  n.mailing_line_2,
  n.mailing_city,
  n.mailing_state,
  n.mailing_zip,
  n.practice_normalized,
  n.mailing_normalized,
  -- B1: expose 9-digit ZIPs for explanation / exports
  loc.nppes_zip9 as b1_nppes_zip9,
  trim(n.pml_zip9) as b1_pml_zip9,
  -- B1 sub-flags (for follow-up and explanation)
  (length(trim(coalesce(n.practice_line_1, ''))) > 0) as b1_nppes_practice_line1_present,
  (n.pml_zip5 is not null and length(trim(coalesce(n.pml_line_1, ''))) > 0) as b1_pml_line1_present,
  (loc.nppes_zip9 is not null) as b1_nppes_zip9_present,
  (n.pml_zip9 is not null) as b1_pml_zip9_present,
  (loc.nppes_zip9 is not null and n.pml_zip9 is not null and loc.nppes_zip9 = trim(n.pml_zip9)) as b1_zip9_match,
  (length(trim(n.practice_city_norm)) > 0 and length(trim(n.pml_city)) > 0 and n.practice_city_norm = n.pml_city) as b1_city_match,
  (length(trim(n.practice_state_norm)) > 0 and length(trim(n.pml_state)) > 0 and n.practice_state_norm = n.pml_state) as b1_state_match,
  -- B1 address status: single value for follow-up (pass or exact fail reason)
  case
    when length(trim(coalesce(n.practice_line_1, ''))) = 0 then 'fail_nppes_practice_line1_empty'
    when n.pml_zip5 is not null and length(trim(coalesce(n.pml_line_1, ''))) = 0 then 'fail_pml_line1_empty'
    when n.pml_zip5 is not null and n.pml_zip9 is null then 'fail_pml_no_zip9'
    when n.pml_zip9 is not null and length(trim(coalesce(n.practice_line_1, ''))) > 0 and loc.nppes_zip9 is null then 'fail_nppes_no_zip9'
    when n.pml_zip9 is not null and length(trim(coalesce(n.practice_line_1, ''))) > 0 and loc.nppes_zip9 is not null and loc.nppes_zip9 != trim(n.pml_zip9) then 'fail_zip9_mismatch'
    else 'pass'
  end as b1_status,
  -- B1 severe (aggregate): address only. Taxonomy = B3.
  (
    (length(trim(coalesce(n.practice_line_1, ''))) = 0)
    or (n.pml_zip5 is not null and (length(trim(coalesce(n.pml_line_1, ''))) = 0 or n.pml_zip9 is null))
    or (n.pml_zip9 is not null and length(trim(coalesce(n.practice_line_1, ''))) > 0 and (loc.nppes_zip9 is null or loc.nppes_zip9 != trim(n.pml_zip9)))
  ) as b1_nppes_pml_mismatch,
  -- B1 warning only: same street (line 1) — when both present and differ.
  (
    length(trim(s.practice_street_norm)) > 0
    and length(trim(s.pml_street_norm)) > 0
    and s.practice_street_norm != s.pml_street_norm
  ) as b1_street_warning,
  -- B2: mailing vs practice differ (info only; not used for status/readiness.)
  (
    n.practice_normalized != n.mailing_normalized
    and length(trim(n.practice_normalized)) > 0
    and length(trim(n.mailing_normalized)) > 0
  ) as b2_mailing_vs_practice_mismatch
from normalized n
left join nppes_loc loc on loc.npi = n.npi
left join nppes_street_norm s on s.npi = n.npi
