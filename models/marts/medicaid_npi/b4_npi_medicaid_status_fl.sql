{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- B4 per-NPI status: flag if NPI has no Medicaid ID in PML; has permissible ID; count of Medicaid IDs.
-- Multiple Medicaid IDs per NPI are supported (roster has one row per id). NPPES match = info only (future).
-- See docs/B4_MEDICAID_ID_ROSTER.md.

with roster_agg as (
  select
    npi,
    count(*) as b4_medicaid_id_count,
    logical_or(b4_permissible) as b4_has_permissible_id
  from {{ ref('b4_medicaid_id_roster_fl') }}
  group by npi
)
select
  n.npi,
  coalesce(r.b4_medicaid_id_count, 0) as b4_medicaid_id_count,
  coalesce(r.b4_has_permissible_id, false) as b4_has_permissible_id,
  (coalesce(r.b4_medicaid_id_count, 0) = 0) as b4_no_medicaid_id_in_pml
from {{ ref('nppes_fl') }} n
left join roster_agg r on r.npi = cast(n.npi as string)
