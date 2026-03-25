{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 2: Address validation report — one place for front end: billing, addresses, NPI name/location, issue status.
-- See docs/FL_MEDICAID_NPI_STEP_NAMING.md and MEDICAID_NPI_PIPELINE_STEPS.md.

with base as (
  select billing_npi, servicing_npi, issue_b1, issue_b2, issue_b3, is_orphan
  from {{ ref('address_validation_fl') }}
),
addr as (
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
    practice_normalized,
    b1_nppes_zip9,
    b1_pml_zip9,
    b1_status
  from {{ ref('npi_addresses_fl') }}
),
-- PML service location (Medicaid enrolled address) for B1 comparison
pml_one as (
  select
    cast(npi as string) as npi,
    trim(coalesce(cast(address_line_1 as string), '')) as pml_address_line_1,
    trim(coalesce(cast(city as string), '')) as pml_city,
    trim(coalesce(cast(state as string), '')) as pml_state,
    trim(coalesce(cast(zip as string), '')) as pml_zip,
    trim(coalesce(cast(zip_plus_4 as string), '')) as pml_zip_plus_4
  from {{ ref('stg_pml_run') }}
  where npi is not null
  qualify row_number() over (partition by cast(npi as string) order by contract_effective_date desc nulls last) = 1
),
-- Org typical (mode) practice address for B3 comparison
pairs as (
  select billing_npi, servicing_npi as npi
  from {{ ref('billing_servicing_pairs_run') }}
  group by 1, 2
),
org_mode_raw as (
  select
    p.billing_npi,
    a.practice_normalized,
    count(*) as npi_count
  from pairs p
  join addr a on a.npi = p.npi
  where a.practice_normalized is not null and length(trim(a.practice_normalized)) > 0
  group by 1, 2
),
org_mode as (
  select billing_npi, practice_normalized as org_typical_practice_address
  from (
    select billing_npi, practice_normalized,
      row_number() over (partition by billing_npi order by npi_count desc) as rn
    from org_mode_raw
  )
  where rn = 1
),
billing_org as (
  select billing_npi, org_name as billing_org_name
  from {{ ref('organizations') }}
),
servicing_names as (
  select
    cast(npi as string) as npi,
    coalesce(
      nullif(trim(coalesce(provider_organization_name_legal_business_name, '')), ''),
      nullif(
        trim(concat(
          coalesce(trim(provider_last_name_legal_name), ''),
          ', ',
          coalesce(trim(provider_first_name), '')
        )),
        ','
      ),
      'Unknown'
    ) as servicing_provider_name
  from {{ ref('nppes_run') }}
)
select
  b.billing_npi,
  coalesce(o.billing_org_name, 'Unknown') as billing_org_name,
  b.servicing_npi,
  coalesce(s.servicing_provider_name, 'Unknown') as servicing_provider_name,
  -- Servicing NPI practice address (NPPES)
  a.practice_line_1 as npi_practice_line_1,
  a.practice_line_2 as npi_practice_line_2,
  a.practice_city as npi_practice_city,
  a.practice_state as npi_practice_state,
  a.practice_zip as npi_practice_zip,
  a.b1_nppes_zip9 as npi_practice_zip9,
  -- Servicing NPI mailing address (NPPES)
  a.mailing_line_1 as npi_mailing_line_1,
  a.mailing_line_2 as npi_mailing_line_2,
  a.mailing_city as npi_mailing_city,
  a.mailing_state as npi_mailing_state,
  a.mailing_zip as npi_mailing_zip,
  -- PML service location (Medicaid enrolled address) — reference for B1
  p.pml_address_line_1,
  p.pml_city as pml_city,
  p.pml_state as pml_state,
  p.pml_zip as pml_zip,
  p.pml_zip_plus_4 as pml_zip_plus_4,
  a.b1_pml_zip9 as pml_zip9,
  -- Org typical practice address — reference for B3
  m.org_typical_practice_address,
  -- B1 status code from npi_addresses
  a.b1_status as b1_status_code,
  -- Issue flags
  b.issue_b1,
  b.issue_b2,
  b.issue_b3,
  b.is_orphan,
  -- Plain-language reason and recommendation
  case when b.issue_b1 then 'NPPES practice address does not match Medicaid (PML) service location — ZIP+9 or address mismatch.'
    else null end as reason_b1,
  case when b.issue_b1 then 'Update NPPES practice address to match PML service location, or update PML so both match the physical service location.'
    else null end as recommendation_b1,
  case when b.issue_b2 then 'Mailing address on file differs from practice address. Often normal (e.g. PO Box for mail).'
    else null end as reason_b2,
  case when b.issue_b2 then 'Confirm practice address is the location where services are rendered.'
    else null end as recommendation_b2,
  case when b.issue_b3 then 'This provider practice address differs from the most common address used by other providers in this billing organization.'
    else null end as reason_b3,
  case when b.issue_b3 then 'Confirm this is a valid separate location; if not, align with the organization main practice address.'
    else null end as recommendation_b3,
  case when b.is_orphan then 'This provider does not map to any site/location in the roster (no address-based sub_org).'
    else null end as reason_orphan,
  case when b.is_orphan then 'Link this NPI to a facility/site in the roster, or confirm they are correctly billed under this billing NPI only.'
    else null end as recommendation_orphan
from base b
left join addr a on a.npi = b.servicing_npi
left join pml_one p on p.npi = b.servicing_npi
left join org_mode m on m.billing_npi = b.billing_npi
left join billing_org o on o.billing_npi = b.billing_npi
left join servicing_names s on s.npi = b.servicing_npi
