{{
  config(
    materialized='table',
  )
}}

-- Org Market Monthly
-- Grain: one row per org_slug × period_month.
-- FL servicing NPIs only (same filter as fl_bh_market_monthly).
-- Org identity: org_npi_map for mapped orgs, billing_npi slug for solo practitioners.
-- Ties exactly to fl_bh_market_monthly at market level.

with bh_codes as (
    select hcpcs_code from {{ ref('stg_bh_codes') }}
),

fl_servicing_npis as (
    select distinct cast(npi as string) as npi
    from {{ source('nppes_public', 'npi_raw') }}
    where npi is not null
      and provider_business_practice_location_address_state_name = 'FL'
),

-- Deduplicate: if a billing NPI maps to multiple orgs, pick the one
-- with the most servicing NPIs (largest footprint under that billing NPI).
org_map as (
    select billing_npi, org_slug
    from (
        select
            cast(billing_npi as string) as billing_npi,
            org_slug,
            row_number() over (partition by billing_npi order by count(*) desc) as rn
        from {{ ref('org_npi_map') }}
        group by 1, 2
    )
    where rn = 1
),

-- All FL BH claims with org assignment
-- Mapped orgs get org_slug from org_npi_map
-- Unmatched billing NPIs become solo practitioner "orgs" (npi-XXXXXXXXXX)
doge_fl_org as (
    select
        coalesce(om.org_slug, concat('npi-', cast(d.billing_npi as string))) as org_slug,
        case when om.org_slug is not null then false else true end as is_solo_practitioner,
        d.period_month,
        cast(d.servicing_npi as string) as servicing_npi,
        d.hcpcs_code,
        cast(d.beneficiary_count as int64)   as beneficiary_count,
        cast(d.claim_count       as int64)   as claim_count,
        cast(d.total_paid        as float64) as total_paid
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    inner join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
    inner join fl_servicing_npis fl on fl.npi = cast(d.servicing_npi as string)
    left join org_map om on om.billing_npi = cast(d.billing_npi as string)
    where d.servicing_npi is not null
      and d.billing_npi   is not null
      and d.period_month   is not null
)

select
    org_slug,
    max(is_solo_practitioner) as is_solo_practitioner,
    period_month,
    left(period_month, 4) as period_year,
    count(distinct servicing_npi) as servicing_npi_count,
    count(distinct hcpcs_code)    as active_codes,
    sum(beneficiary_count)        as total_beneficiaries,
    sum(claim_count)              as total_claims,
    sum(total_paid)               as total_paid,
    safe_divide(sum(total_paid), sum(beneficiary_count)) as rate_per_beneficiary,
    safe_divide(sum(total_paid), sum(claim_count))       as rate_per_claim,
    safe_divide(sum(total_paid), count(distinct servicing_npi)) as revenue_per_provider
from doge_fl_org
group by 1, 3, 4
