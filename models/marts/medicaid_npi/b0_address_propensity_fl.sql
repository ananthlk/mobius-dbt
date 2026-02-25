{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- B0 Address propensity: (npi, sub_org_id) with match_type = strong | partial.
-- Strong: same practice_normalized, same mailing_normalized, or same ZIP+9. Partial: same ZIP5, same street, same city+state.
-- NPIs can appear in multiple sub-orgs. See B0 plan.

with sub_org as (
  select sub_org_id, org_id, address_normalized, zip5, zip9, address_line_1, city, state
  from {{ ref('b0_sub_org_address_fl') }}
),
npi_addr as (
  select
    cast(npi as string) as npi,
    practice_normalized,
    mailing_normalized,
    b1_nppes_zip9 as npi_zip9,
    case when b1_nppes_zip9 is not null and length(b1_nppes_zip9) >= 5 then substr(b1_nppes_zip9, 1, 5) else null end as npi_zip5,
    upper(trim(regexp_replace(coalesce(practice_line_1, ''), r'\s+', ' '))) as practice_street_norm,
    upper(trim(coalesce(practice_city, ''))) as practice_city_norm,
    upper(trim(coalesce(practice_state, ''))) as practice_state_norm
  from {{ ref('npi_addresses_fl') }}
  where npi is not null
),
-- Cartesian avoided: join on zip5 first to reduce pair count, then classify match.
-- Fallback: for NPIs with null zip5, restrict to same-state sub_orgs (smaller set).
pairs as (
  select
    a.npi,
    s.sub_org_id,
    s.org_id,
    (a.practice_normalized is not null and a.practice_normalized = s.address_normalized) as same_practice,
    (a.mailing_normalized is not null and a.mailing_normalized = s.address_normalized) as same_mailing,
    (a.npi_zip9 is not null and s.zip9 is not null and a.npi_zip9 = s.zip9) as same_zip9,
    (a.npi_zip5 is not null and s.zip5 is not null and a.npi_zip5 = s.zip5) as same_zip5,
    (length(a.practice_street_norm) > 0 and length(trim(s.address_line_1)) > 0
     and upper(trim(regexp_replace(coalesce(s.address_line_1, ''), r'\s+', ' '))) = a.practice_street_norm) as same_street,
    (length(a.practice_city_norm) > 0 and length(trim(s.city)) > 0 and a.practice_city_norm = upper(trim(s.city))
     and length(a.practice_state_norm) > 0 and length(trim(s.state)) > 0 and a.practice_state_norm = upper(trim(s.state))) as same_city_state
  from npi_addr a
  inner join sub_org s
    on (a.npi_zip5 is not null and s.zip5 is not null and a.npi_zip5 = s.zip5)
    or (a.npi_zip5 is null
        and a.practice_state_norm = upper(trim(s.state))
        and length(a.practice_city_norm) > 0 and a.practice_city_norm = upper(trim(s.city)))
),
classified as (
  select
    npi,
    sub_org_id,
    org_id,
    case
      when same_practice or same_mailing or same_zip9 then 'strong'
      when same_zip5 or same_street or same_city_state then 'partial'
      else null
    end as match_type
  from pairs
  where same_practice or same_mailing or same_zip9 or same_zip5 or same_street or same_city_state
)
select npi, sub_org_id, org_id, match_type
from classified
