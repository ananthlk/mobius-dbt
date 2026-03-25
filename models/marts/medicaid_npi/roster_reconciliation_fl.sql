{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Roster reconciliation: compare internal (upload) vs external (outside-in) roster.
-- Requires var roster_upload_id and roster_org_id (billing_npi from organizations match).
-- reconciliation_status: in_both | external_only | internal_only

with internal as (
  select distinct
    upload_id,
    org_name,
    lpad(trim(npi), 10, '0') as npi
  from {{ ref('internal_roster') }}
  where upload_id = '{{ var("roster_upload_id", "") }}'
),
external as (
  select distinct
    org_id,
    lpad(trim(npi), 10, '0') as npi
  from {{ ref('b0_roster_list_fl') }}
  where org_id = '{{ var("roster_org_id", "") }}'
),
in_both as (
  select i.upload_id, i.org_name, i.npi, 'in_both' as reconciliation_status
  from internal i
  inner join external e on e.npi = i.npi
),
external_only as (
  select
    '{{ var("roster_upload_id", "") }}' as upload_id,
    '{{ var("roster_org_name", "") }}' as org_name,
    e.npi,
    'external_only' as reconciliation_status
  from external e
  left join internal i on i.npi = e.npi
  where i.npi is null
),
internal_only as (
  select i.upload_id, i.org_name, i.npi, 'internal_only' as reconciliation_status
  from internal i
  left join external e on e.npi = i.npi
  where e.npi is null
)
select * from in_both
union all
select * from external_only
union all
select * from internal_only
