{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Billing → servicing pairs: DOGE (claims) + address match from NPPES (facility→member at same site).
-- DOGE: claims-based pairs with volume. Address match: facility NPI as billing, member NPI as servicing (claim_count=0).

with doge as (
  select
    cast(billing_npi as string) as billing_npi,
    cast(servicing_npi as string) as servicing_npi,
    coalesce(claim_count, 1) as claim_count,
    coalesce(total_paid, 0) as total_paid,
    coalesce(beneficiary_count, 0) as beneficiary_count,
    hcpcs_code
  from {{ source('landing_medicaid_npi', 'stg_doge') }}
  where billing_npi is not null and servicing_npi is not null
),
-- Address-based: facility (org_id) → member (npi) from NPPES address match (b0_sub_org_members_fl)
addr_pairs as (
  select
    cast(org_id as string) as billing_npi,
    cast(npi as string) as servicing_npi
  from {{ ref('b0_sub_org_members_fl') }}
  where org_id is not null and npi is not null
)
select
  coalesce(d.billing_npi, a.billing_npi) as billing_npi,
  coalesce(d.servicing_npi, a.servicing_npi) as servicing_npi,
  coalesce(d.claim_count, 0) as claim_count,
  coalesce(d.total_paid, 0) as total_paid,
  coalesce(d.beneficiary_count, 0) as beneficiary_count,
  d.hcpcs_code
from addr_pairs a
left join doge d on d.billing_npi = a.billing_npi and d.servicing_npi = a.servicing_npi
union all
select
  d.billing_npi,
  d.servicing_npi,
  d.claim_count,
  d.total_paid,
  d.beneficiary_count,
  d.hcpcs_code
from doge d
where not exists (
  select 1 from addr_pairs a
  where a.billing_npi = d.billing_npi and a.servicing_npi = d.servicing_npi
)
