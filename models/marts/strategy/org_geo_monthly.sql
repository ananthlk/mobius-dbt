{{
  config(
    materialized='table',
  )
}}

-- Org Geo Monthly
-- Grain: one row per org_slug × zip5 × period_month.
-- Maps each org to the ZIPs their servicing NPIs practice in,
-- enriched with RUCA classification and market-level supply/demand context.
-- Enables: market footprint analysis, urban/rural mix, desert exposure.

with bh_codes as (
    select hcpcs_code from {{ ref('stg_bh_codes') }}
),

fl_npis_with_zip as (
    select distinct
        cast(npi as string) as npi,
        left(trim(cast(provider_business_mailing_address_postal_code as string)), 5) as zip5
    from {{ source('nppes_public', 'npi_raw') }}
    where npi is not null
      and provider_business_practice_location_address_state_name = 'FL'
      and provider_business_mailing_address_postal_code is not null
),

-- Deduplicate billing NPI → org (same logic as org_market_monthly)
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

-- Org × ZIP × month from claims
org_zip_month as (
    select
        coalesce(om.org_slug, concat('npi-', cast(d.billing_npi as string))) as org_slug,
        case when om.org_slug is not null then false else true end as is_solo_practitioner,
        fl.zip5,
        d.period_month,
        count(distinct d.servicing_npi)      as provider_count,
        sum(cast(d.beneficiary_count as int64))  as total_beneficiaries,
        sum(cast(d.claim_count       as int64))  as total_claims,
        sum(cast(d.total_paid        as float64)) as total_paid
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    inner join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
    inner join fl_npis_with_zip fl on fl.npi = cast(d.servicing_npi as string)
    left join org_map om on om.billing_npi = cast(d.billing_npi as string)
    where d.servicing_npi is not null
      and d.billing_npi   is not null
      and d.period_month   is not null
    group by 1, 2, 3, 4
)

select
    oz.org_slug,
    oz.is_solo_practitioner,
    oz.zip5,
    coalesce(r.po_name, 'Unknown')       as po_name,
    coalesce(r.ruca_category, 'unknown')  as ruca_category,
    coalesce(r.primary_ruca, 'unknown')   as primary_ruca,
    oz.period_month,
    left(oz.period_month, 4)              as period_year,
    oz.provider_count,
    oz.total_beneficiaries,
    oz.total_claims,
    oz.total_paid,

    -- Market context from market_geo_monthly (ZIP-level totals)
    mg.provider_count       as market_providers_in_zip,
    mg.total_beneficiaries  as market_benes_in_zip,
    mg.total_paid           as market_paid_in_zip,
    mg.supply_demand_flag   as market_supply_demand_flag,

    -- Org's share of this ZIP's market
    safe_divide(oz.total_paid, mg.total_paid)               as zip_paid_share,
    safe_divide(oz.total_beneficiaries, mg.total_beneficiaries) as zip_bene_share,
    safe_divide(oz.provider_count, mg.provider_count)        as zip_provider_share

from org_zip_month oz
left join {{ ref('ruca_fl_zips') }} r on r.zip5 = oz.zip5
left join {{ ref('market_geo_monthly') }} mg
    on mg.zip5 = oz.zip5
    and mg.period_month = oz.period_month
