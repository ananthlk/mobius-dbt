{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- B0 Roster list: union of (1) address-based org/sub-org/NPI + associated member NPIs,
-- and (2) billing-NPI-based group + member NPIs. Output: org_id, sub_org_id, npi, tin, associated_member_npis.
-- See docs/B0_ROSTER_AND_ORG_STRUCTURE_PLAN.md.

with sub_org_members as (
  select sub_org_id, org_id, npi from {{ ref('b0_sub_org_members_fl') }}
),
-- Pre-aggregate: one row per (sub_org_id, org_id) with all NPIs. Avoids O(n²) self-join.
sub_org_npis as (
  select sub_org_id, org_id, array_agg(npi order by npi) as all_npis
  from sub_org_members
  group by sub_org_id, org_id
),
sub_org_with_assoc as (
  select
    m.sub_org_id,
    m.org_id,
    m.npi,
    coalesce(
      (select array_agg(x order by x) from unnest(a.all_npis) as x where x != m.npi),
      []
    ) as associated_member_npis
  from sub_org_members m
  inner join sub_org_npis a using (sub_org_id, org_id)
),
-- Address-based roster rows
address_based as (
  select
    org_id,
    sub_org_id,
    npi,
    cast(null as string) as tin,
    associated_member_npis,
    'address' as source_type,
    cast(null as string) as billing_npi
  from sub_org_with_assoc
),
-- Billing-NPI-based: pre-aggregate member NPIs per billing_npi, then derive associated (others) per row.
billing_member_list as (
  select billing_npi, array_agg(member_npi order by member_npi) as member_npis
  from {{ ref('b0_billing_npi_members_fl') }}
  group by billing_npi
),
billing_based as (
  select
    p.billing_npi as org_id,
    cast(null as string) as sub_org_id,
    p.member_npi as npi,
    cast(null as string) as tin,
    coalesce(
      (select array_agg(x order by x) from unnest(b.member_npis) as x where x != p.member_npi),
      []
    ) as associated_member_npis,
    'billing_npi' as source_type,
    p.billing_npi as billing_npi
  from {{ ref('b0_billing_npi_members_fl') }} p
  inner join billing_member_list b on b.billing_npi = p.billing_npi
)
select org_id, sub_org_id, npi, tin, associated_member_npis, source_type, billing_npi from address_based
union all
select org_id, sub_org_id, npi, tin, associated_member_npis, source_type, billing_npi from billing_based
