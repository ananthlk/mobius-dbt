{{
  config(
    materialized='table',
  )
}}

-- Micro-Market Concentration
-- Grain: one row per micro_market × ahca_category × period_month.
-- Computes HHI, top-3 share, org count, and market structure classification.
-- Displacement dynamics differ fundamentally in monopoly vs fragmented markets.

with shares as (
    select
        micro_market,
        ahca_category,
        period_month,
        left(period_month, 4) as period_year,
        org_slug,
        revenue_share,
        bene_share,
        total_paid,
        total_beneficiaries
    from {{ ref('org_micro_market_share') }}
    where micro_market != 'unmapped'
),

-- HHI = sum of squared market shares (revenue-based)
-- Range: 0 to 1. >0.25 = highly concentrated, 0.15-0.25 = moderate, <0.15 = competitive
hhi as (
    select
        micro_market,
        ahca_category,
        period_month,
        sum(revenue_share * revenue_share) as hhi_revenue,
        sum(bene_share * bene_share)       as hhi_bene
    from shares
    group by 1, 2, 3
),

-- Top-N shares
ranked as (
    select
        micro_market,
        ahca_category,
        period_month,
        org_slug,
        revenue_share,
        row_number() over (
            partition by micro_market, ahca_category, period_month
            order by revenue_share desc
        ) as rank_in_market
    from shares
),

top_n as (
    select
        micro_market,
        ahca_category,
        period_month,
        max(case when rank_in_market = 1 then org_slug end) as top1_org,
        max(case when rank_in_market = 1 then revenue_share end) as top1_share,
        max(case when rank_in_market = 2 then org_slug end) as top2_org,
        max(case when rank_in_market = 2 then revenue_share end) as top2_share,
        max(case when rank_in_market = 3 then org_slug end) as top3_org,
        max(case when rank_in_market = 3 then revenue_share end) as top3_share,
        sum(case when rank_in_market <= 3 then revenue_share else 0 end) as top3_combined_share
    from ranked
    group by 1, 2, 3
),

-- Market totals
totals as (
    select
        micro_market,
        ahca_category,
        period_month,
        period_year,
        count(distinct org_slug)    as org_count,
        sum(total_paid)             as market_paid,
        sum(total_beneficiaries)    as market_beneficiaries
    from shares
    group by 1, 2, 3, 4
)

select
    t.micro_market,
    t.ahca_category,
    t.period_month,
    t.period_year,

    -- Market size
    t.org_count,
    t.market_paid,
    t.market_beneficiaries,

    -- Concentration
    h.hhi_revenue,
    h.hhi_bene,

    -- Market structure classification
    case
        when h.hhi_revenue >= 0.25 then 'highly_concentrated'
        when h.hhi_revenue >= 0.15 then 'moderately_concentrated'
        when h.hhi_revenue >= 0.05 then 'competitive'
        else 'fragmented'
    end as market_structure,

    -- Top orgs
    tn.top1_org,
    tn.top1_share,
    tn.top2_org,
    tn.top2_share,
    tn.top3_org,
    tn.top3_share,
    tn.top3_combined_share,

    -- Effective number of competitors (1/HHI)
    safe_divide(1.0, h.hhi_revenue) as effective_competitors

from totals t
left join hhi h
    on h.micro_market = t.micro_market
    and h.ahca_category = t.ahca_category
    and h.period_month = t.period_month
left join top_n tn
    on tn.micro_market = t.micro_market
    and tn.ahca_category = t.ahca_category
    and tn.period_month = t.period_month
