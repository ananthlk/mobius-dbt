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
-- Associated member NPIs per (sub_org_id, npi): all other NPIs in that sub-org
sub_org_with_assoc as (
  select
    a.sub_org_id,
    a.org_id,
    a.npi,
    array_agg(b.npi ignore nulls order by b.npi) as associated_member_npis
  from sub_org_members a
  left join sub_org_members b on b.sub_org_id = a.sub_org_id and b.npi != a.npi
  group by a.sub_org_id, a.org_id, a.npi
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
-- Billing-NPI-based: one row per (billing_npi, member_npi) with list of all other member NPIs
billing_member_list as (
  select billing_npi, array_agg(member_npi order by member_npi) as member_npis
  from {{ ref('b0_billing_npi_members_fl') }}
  group by billing_npi
),
billing_with_others as (
  select b.billing_npi, p.member_npi, array_agg(om order by om) as associated_member_npis
  from billing_member_list b
  inner join {{ ref('b0_billing_npi_members_fl') }} p on p.billing_npi = b.billing_npi
  cross join unnest(b.member_npis) as om
  where om != p.member_npi
  group by b.billing_npi, p.member_npi
),
billing_based as (
  select
    p.billing_npi as org_id,
    cast(null as string) as sub_org_id,
    p.member_npi as npi,
    cast(null as string) as tin,
    coalesce(o.associated_member_npis, []) as associated_member_npis,
    'billing_npi' as source_type,
    p.billing_npi as billing_npi
  from {{ ref('b0_billing_npi_members_fl') }} p
  left join billing_with_others o on o.billing_npi = p.billing_npi and o.member_npi = p.member_npi
)
select org_id, sub_org_id, npi, tin, associated_member_npis, source_type, billing_npi from address_based
union all
select org_id, sub_org_id, npi, tin, associated_member_npis, source_type, billing_npi from billing_based
