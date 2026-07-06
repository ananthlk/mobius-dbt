{{
  config(
    materialized='table',
  )
}}

-- Org Micro-Market Share
-- Grain: one row per org_slug × micro_market × ahca_category × period_month.
-- Computes each org's share of revenue and beneficiaries within each
-- micro-market (MSA/county) × service category.
-- Enables displacement detection at the local market level.

with bh_codes as (
    select hcpcs_code, ahca_category
    from {{ ref('stg_bh_codes') }}
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

-- Claims at org × ZIP × ahca_category × month
org_zip_cat_month as (
    select
        coalesce(om.org_slug, concat('npi-', cast(d.billing_npi as string))) as org_slug,
        fl.zip5,
        bh.ahca_category,
        d.period_month,
        left(d.period_month, 4) as period_year,
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
    group by 1, 2, 3, 4, 5
),

-- Roll up to org × micro_market × ahca_category × month
-- LEFT JOIN: ZIPs not in seed (out-of-state mailing, PO box-only) → 'unmapped'
org_mm as (
    select
        o.org_slug,
        coalesce(mm.micro_market, 'unmapped') as micro_market,
        coalesce(mm.county_name, 'unmapped')  as county_name,
        mm.msa_name,
        o.ahca_category,
        o.period_month,
        o.period_year,
        sum(o.total_beneficiaries) as total_beneficiaries,
        sum(o.total_claims)        as total_claims,
        sum(o.total_paid)          as total_paid
    from org_zip_cat_month o
    left join {{ ref('fl_zip_micro_market') }} mm on mm.zip5 = o.zip5
    group by 1, 2, 3, 4, 5, 6, 7
),

-- Market totals per micro_market × ahca_category × month
market_mm as (
    select
        micro_market,
        ahca_category,
        period_month,
        sum(total_beneficiaries) as mkt_beneficiaries,
        sum(total_claims)        as mkt_claims,
        sum(total_paid)          as mkt_paid,
        count(distinct org_slug) as mkt_org_count
    from org_mm
    group by 1, 2, 3
)

select
    o.org_slug,
    o.micro_market,
    o.county_name,
    o.msa_name,
    o.ahca_category,
    o.period_month,
    o.period_year,

    -- Org volumes
    o.total_beneficiaries,
    o.total_claims,
    o.total_paid,

    -- Market totals in this micro-market × category
    m.mkt_beneficiaries,
    m.mkt_claims,
    m.mkt_paid,
    m.mkt_org_count,

    -- Share of micro-market
    safe_divide(o.total_paid, m.mkt_paid)                   as revenue_share,
    safe_divide(o.total_beneficiaries, m.mkt_beneficiaries)  as bene_share,
    safe_divide(o.total_claims, m.mkt_claims)                as claim_share,

    -- Prior month shares (for MoM share delta within micro-market)
    lag(safe_divide(o.total_paid, m.mkt_paid)) over (
        partition by o.org_slug, o.micro_market, o.ahca_category
        order by o.period_month
    ) as prior_month_revenue_share,
    lag(safe_divide(o.total_beneficiaries, m.mkt_beneficiaries)) over (
        partition by o.org_slug, o.micro_market, o.ahca_category
        order by o.period_month
    ) as prior_month_bene_share

from org_mm o
left join market_mm m
    on m.micro_market = o.micro_market
    and m.ahca_category = o.ahca_category
    and m.period_month = o.period_month
