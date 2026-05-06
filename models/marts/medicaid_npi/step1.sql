{{
  config(
    enabled=false,
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- DISABLED 2026-04-23: Scanned 21.46 TiB per run (~$134) via b0_roster_list_fl. Zero non-dbt readers.
-- Step 1: Roster list (org_id, site_id, npi, org_name, site address, …).
-- Self-sufficient table for front end. See docs/FL_MEDICAID_NPI_STEP_OUTPUTS.md.

with roster as (
  select
    org_id,
    sub_org_id,
    npi,
    tin,
    associated_member_npis,
    source_type,
    billing_npi
  from {{ ref('b0_roster_list_fl') }}
),
site_addr as (
  select
    sub_org_id,
    address_line_1 as site_address_line_1,
    city as site_city,
    state as site_state,
    zip5 as site_zip5,
    zip9 as site_zip9
  from {{ ref('b0_sub_org_address_fl') }}
),
org_from_nppes as (
  select
    cast(npi as string) as npi,
    coalesce(
      nullif(trim(coalesce(provider_organization_name_legal_business_name, '')), ''),
      nullif(trim(concat(coalesce(trim(provider_last_name_legal_name), ''), ', ', coalesce(trim(provider_first_name), ''))), ','),
      'Unknown'
    ) as org_name
  from {{ ref('nppes_run') }}
),
org_from_billing as (
  select billing_npi, org_name
  from {{ ref('organizations') }}
),
npi_names as (
  select
    cast(npi as string) as npi,
    coalesce(
      nullif(trim(coalesce(provider_organization_name_legal_business_name, '')), ''),
      nullif(trim(concat(coalesce(trim(provider_last_name_legal_name), ''), ', ', coalesce(trim(provider_first_name), ''))), ','),
      'Unknown'
    ) as npi_provider_name
  from {{ ref('nppes_run') }}
)
select
  r.org_id,
  r.sub_org_id,
  r.npi,
  r.tin,
  r.associated_member_npis,
  r.source_type,
  r.billing_npi,
  coalesce(
    case when r.source_type = 'address' then o_nppes.org_name end,
    case when r.source_type = 'billing_npi' then o_bill.org_name end,
    'Unknown'
  ) as org_name,
  s.site_address_line_1,
  s.site_city,
  s.site_state,
  s.site_zip5,
  s.site_zip9,
  coalesce(n.npi_provider_name, 'Unknown') as npi_provider_name,
  case
    when r.source_type = 'address' and r.sub_org_id is not null then
      'Roster row for ' || coalesce(o_nppes.org_name, 'Unknown') || ' at site ' || coalesce(s.site_address_line_1 || ', ' || s.site_city || ' ' || s.site_state, 'N/A') || '. Source: address-based facility match.'
    when r.source_type = 'billing_npi' then
      'Roster row for ' || coalesce(o_bill.org_name, 'Unknown') || '. Source: billing NPI group (no site/location).'
    else
      'Roster row for org ' || r.org_id || ', NPI ' || r.npi || '.'
  end as step_explanation
from roster r
left join site_addr s on s.sub_org_id = r.sub_org_id
left join org_from_nppes o_nppes on o_nppes.npi = r.org_id and r.source_type = 'address'
left join org_from_billing o_bill on o_bill.billing_npi = r.org_id and r.source_type = 'billing_npi'
left join npi_names n on n.npi = r.npi
