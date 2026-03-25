{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
    partition_by={
      'field': 'report_date',
      'data_type': 'date',
    },
    cluster_by=['org_id', 'npi', 'org_display_name', 'npi_provider_name'],
  )
}}

-- B6 Integrated report: single read head. Query by org_id, npi, site_id, org_display_name, or npi_provider_name.
-- Front end and chat use only this; B0–B5 are obfuscated. Table is partitioned by report_date, clustered for live lookups.
-- See docs/B6_INTEGRATED_REPORT.md and docs/B6_VIEW_PERFORMANCE.md.

with roster as (
  select
    org_id,
    sub_org_id as site_id,
    npi,
    tin,
    associated_member_npis,
    source_type,
    billing_npi
  from {{ ref('b0_roster_list_fl') }}
),
b1b2 as (
  select
    cast(npi as string) as npi,
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
    b1_status,
    b1_nppes_pml_mismatch,
    b1_zip9_match,
    b1_nppes_zip9,
    b1_pml_zip9,
    b1_nppes_practice_line1_present,
    b1_pml_line1_present,
    b1_nppes_zip9_present,
    b1_pml_zip9_present,
    b1_city_match,
    b1_state_match,
    b1_street_warning,
    b2_mailing_vs_practice_mismatch
  from {{ ref('npi_addresses_fl') }}
),
b3 as (
  select
    npi,
    b3_status,
    b3_at_least_one_viable_in_fl,
    b3_no_viable_in_fl,
    b3_nppes_taxonomy_count,
    b3_fl_allowed_count
  from {{ ref('b3_taxonomy_alignment_fl') }}
),
b4_status as (
  select
    npi,
    b4_medicaid_id_count,
    b4_has_permissible_id,
    b4_no_medicaid_id_in_pml
  from {{ ref('b4_npi_medicaid_status_fl') }}
),
b4_roster_agg as (
  select
    npi,
    array_agg(struct(medicaid_provider_id, b4_permissible) order by medicaid_provider_id) as b4_medicaid_ids
  from {{ ref('b4_medicaid_id_roster_fl') }}
  group by npi
),
site_addr as (
  select sub_org_id, address_line_1 as site_address_line_1, city as site_city, state as site_state, zip5 as site_zip5, zip9 as site_zip9
  from {{ ref('b0_sub_org_address_fl') }}
),
org_names as (
  select
    cast(npi as string) as npi,
    coalesce(provider_organization_name_legal_business_name, concat(provider_last_name_legal_name, ', ', provider_first_name)) as provider_name
  from {{ ref('nppes_run') }}
),
organizations as (
  select billing_npi, org_name as billing_org_name
  from {{ ref('organizations') }}
),
base as (
  select
    r.org_id,
    r.site_id,
    r.npi,
    r.tin,
    r.associated_member_npis,
    r.source_type,
    r.billing_npi,
    o_npi.provider_name as npi_provider_name,
    o_org.provider_name as org_provider_name,
    o_billing.billing_org_name,
    coalesce(o_org.provider_name, o_billing.billing_org_name) as org_display_name,
    s.site_address_line_1,
    s.site_city,
    s.site_state,
    s.site_zip5,
    s.site_zip9
  from roster r
  left join org_names o_npi on o_npi.npi = r.npi
  left join org_names o_org on o_org.npi = r.org_id and r.source_type = 'address'
  left join organizations o_billing on o_billing.billing_npi = r.org_id and r.source_type = 'billing_npi'
  left join site_addr s on s.sub_org_id = r.site_id
)
select
  current_date() as report_date,
  b.org_id,
  b.site_id,
  b.npi,
  b.tin,
  b.associated_member_npis,
  b.source_type,
  b.billing_npi,
  b.npi_provider_name,
  b.org_display_name,
  b.site_address_line_1,
  b.site_city,
  b.site_state,
  b.site_zip5,
  b.site_zip9,
  -- B1
  a.b1_status,
  a.b1_nppes_pml_mismatch,
  a.b1_zip9_match,
  a.b1_nppes_zip9,
  a.b1_pml_zip9,
  a.b1_nppes_practice_line1_present,
  a.b1_pml_line1_present,
  a.b1_nppes_zip9_present,
  a.b1_pml_zip9_present,
  a.b1_city_match,
  a.b1_state_match,
  a.b1_street_warning,
  -- B2
  a.b2_mailing_vs_practice_mismatch,
  a.practice_line_1,
  a.practice_line_2,
  a.practice_city,
  a.practice_state,
  a.practice_zip,
  a.mailing_line_1,
  a.mailing_line_2,
  a.mailing_city,
  a.mailing_state,
  a.mailing_zip,
  -- B3
  t.b3_status,
  t.b3_at_least_one_viable_in_fl,
  t.b3_no_viable_in_fl,
  t.b3_nppes_taxonomy_count,
  t.b3_fl_allowed_count,
  -- B4
  f.b4_medicaid_id_count,
  f.b4_has_permissible_id,
  f.b4_no_medicaid_id_in_pml,
  r4.b4_medicaid_ids,
  -- B5: pass only when B1, B3, and B4 all pass
  (
    coalesce(a.b1_status, '') = 'pass'
    and coalesce(t.b3_status, '') = 'pass'
    and coalesce(f.b4_has_permissible_id, false) = true
  ) as b5_pass,
  case
    when coalesce(a.b1_status, '') != 'pass' then 'b1_site'
    when coalesce(t.b3_status, '') != 'pass' then 'b3_taxonomy'
    when coalesce(f.b4_has_permissible_id, false) != true then 'b4_medicaid_id'
    else null
  end as b5_fail_reason
from base b
left join b1b2 a on a.npi = b.npi
left join b3 t on t.npi = b.npi
left join b4_status f on f.npi = b.npi
left join b4_roster_agg r4 on r4.npi = b.npi
