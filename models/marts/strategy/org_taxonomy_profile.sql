{{
  config(
    materialized='table',
  )
}}

-- Org Taxonomy Profile
-- Grain: one row per org_slug × taxonomy_code × period_month.
-- Indexes each org's rate (rpb, rpc) against the taxonomy peer group
-- market rate (from taxonomy_market_monthly), not just overall FL market.
-- Enables: "is this org expensive for the type of clinicians it employs?"

with bh_codes as (
    select hcpcs_code from {{ ref('stg_bh_codes') }}
),

bh_tax as (
    select taxonomy_code from {{ ref('stg_bh_taxonomies') }}
),

fl_npis_with_taxonomy as (
    select distinct
        cast(npi as string) as npi,
        healthcare_provider_taxonomy_code_1 as taxonomy_code
    from {{ source('nppes_public', 'npi_raw') }}
    where npi is not null
      and provider_business_practice_location_address_state_name = 'FL'
      and healthcare_provider_taxonomy_code_1 is not null
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

-- Org × taxonomy × month from claims
org_tax_month as (
    select
        coalesce(om.org_slug, concat('npi-', cast(d.billing_npi as string))) as org_slug,
        fl.taxonomy_code,
        d.period_month,
        left(d.period_month, 4) as period_year,
        count(distinct d.servicing_npi)          as provider_count,
        sum(cast(d.beneficiary_count as int64))  as total_beneficiaries,
        sum(cast(d.claim_count       as int64))  as total_claims,
        sum(cast(d.total_paid        as float64)) as total_paid
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    inner join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
    inner join fl_npis_with_taxonomy fl on fl.npi = cast(d.servicing_npi as string)
    inner join bh_tax bt on bt.taxonomy_code = fl.taxonomy_code
    left join org_map om on om.billing_npi = cast(d.billing_npi as string)
    where d.servicing_npi is not null
      and d.billing_npi   is not null
      and d.period_month   is not null
    group by 1, 2, 3, 4
)

select
    ot.org_slug,
    ot.taxonomy_code,
    tm.nucc_display_name,
    tm.nucc_classification,
    ot.period_month,
    ot.period_year,

    -- Org volumes for this taxonomy
    ot.provider_count,
    ot.total_beneficiaries,
    ot.total_claims,
    ot.total_paid,

    -- Org rates
    safe_divide(ot.total_paid, ot.total_beneficiaries) as org_rpb,
    safe_divide(ot.total_paid, ot.total_claims)        as org_rpc,
    safe_divide(ot.total_paid, ot.provider_count)      as org_revenue_per_provider,

    -- Taxonomy peer group market rates
    tm.rate_per_beneficiary as peer_rpb,
    tm.rate_per_claim       as peer_rpc,
    tm.avg_revenue_per_provider as peer_revenue_per_provider,
    tm.provider_count       as peer_provider_count,

    -- Rate indexes vs taxonomy peers
    safe_divide(
        safe_divide(ot.total_paid, ot.total_beneficiaries),
        tm.rate_per_beneficiary
    ) as rpb_index,
    safe_divide(
        safe_divide(ot.total_paid, ot.total_claims),
        tm.rate_per_claim
    ) as rpc_index,
    safe_divide(
        safe_divide(ot.total_paid, ot.provider_count),
        tm.avg_revenue_per_provider
    ) as revenue_per_provider_index,

    -- Org's share of this taxonomy's market
    safe_divide(ot.total_paid, tm.total_paid)               as taxonomy_paid_share,
    safe_divide(ot.total_beneficiaries, tm.total_beneficiaries) as taxonomy_bene_share,
    safe_divide(ot.provider_count, tm.provider_count)        as taxonomy_provider_share

from org_tax_month ot
left join {{ ref('taxonomy_market_monthly') }} tm
    on tm.taxonomy_code = ot.taxonomy_code
    and tm.period_month = ot.period_month
