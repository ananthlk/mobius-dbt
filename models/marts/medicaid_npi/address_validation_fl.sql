{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Address validation flags: B1 (NPPES vs PML ZIP), B2 (NPPES internal), B3 (within billing org).
-- Orphan: servicing NPI that does not map to any site (no roster row with sub_org_id).

with pairs as (
  select billing_npi, servicing_npi as npi
  from {{ ref('billing_servicing_pairs_run') }}
  group by 1, 2
),
-- NPIs that appear in the roster with a site (sub_org_id not null) — they map to a location
npis_with_site as (
  select distinct npi
  from {{ ref('b0_roster_list_fl') }}
  where sub_org_id is not null
),
addr as (
  select npi, practice_normalized, b1_nppes_pml_mismatch, b2_mailing_vs_practice_mismatch
  from {{ ref('npi_addresses_fl') }}
),
-- Mode address per billing org: most common practice_normalized among servicing NPIs
org_mode_address as (
  select
    p.billing_npi,
    a.practice_normalized,
    count(*) as npi_count
  from pairs p
  join addr a on a.npi = p.npi
  where a.practice_normalized is not null
    and length(trim(a.practice_normalized)) > 0
  group by 1, 2
),
org_mode as (
  select billing_npi, practice_normalized as mode_address
  from (
    select
      billing_npi,
      practice_normalized,
      row_number() over (partition by billing_npi order by npi_count desc) as rn
    from org_mode_address
  )
  where rn = 1
)
select
  p.billing_npi,
  p.npi as servicing_npi,
  coalesce(a.b1_nppes_pml_mismatch, false) as issue_b1,
  coalesce(a.b2_mailing_vs_practice_mismatch, false) as issue_b2,
  (
    a.practice_normalized is not null
    and m.mode_address is not null
    and a.practice_normalized != m.mode_address
  ) as issue_b3,
  (s.npi is null) as is_orphan
from pairs p
left join addr a on a.npi = p.npi
left join org_mode m on m.billing_npi = p.billing_npi
left join npis_with_site s on s.npi = p.npi
