{{
  config(
    materialized='table',
  )
}}

-- Displacement Feature Matrix
-- Grain: one row per org_slug × micro_market × ahca_category × period_month.
-- The ML-ready longitudinal record joining all feature lenses with displacement targets.
-- No prior-year filter — all rows included. MoM and 3-month targets are primary.

with targets as (
    select * from {{ ref('displacement_targets') }}
),

-- Org-level features (monthly)
org_monthly as (
    select
        org_slug,
        period_month,
        is_solo_practitioner,
        servicing_npi_count,
        active_codes,
        total_beneficiaries as org_total_benes,
        total_claims        as org_total_claims,
        total_paid          as org_total_paid,
        rate_per_beneficiary as org_rpb,
        rate_per_claim       as org_rpc,
        revenue_per_provider as org_revenue_per_provider
    from {{ ref('org_market_monthly') }}
),

-- Org market profile (geographic footprint)
org_profile as (
    select
        org_slug,
        period_month,
        zip_count,
        pct_revenue_urban,
        pct_revenue_rural,
        pct_revenue_desert,
        pct_revenue_shortage,
        weighted_avg_market_share,
        market_type,
        operating_footprint
    from {{ ref('org_market_profile') }}
),

-- Org workforce composition
workforce as (
    select
        org_slug,
        period_month,
        total_providers,
        psychiatrist_pct,
        counselor_pct,
        social_worker_pct,
        psychologist_pct,
        aprn_pct,
        sud_specialist_pct,
        workforce_category_count,
        dominant_workforce_type
    from {{ ref('org_workforce_profile') }}
),

-- Org rate profile for this service category
rate_profile as (
    select
        org_slug,
        ahca_category,
        period_month,
        rpb_index as category_rpb_index,
        rpc_index as category_rpc_index,
        rate_index as category_rate_index
    from {{ ref('org_rate_profile') }}
),

-- Whether org offers this service (from service mix)
service_mix as (
    select
        org_slug,
        ahca_category,
        period_month,
        offers_service
    from {{ ref('org_service_mix') }}
),

-- Entry/exit context for this org × micro-market × category
entry_exit as (
    select
        org_slug,
        micro_market,
        ahca_category,
        period_month,
        months_since_entry,
        tenure_stage,
        is_first_month,
        is_returning,
        is_entering,
        is_last_observed_month,
        is_continuously_active
    from {{ ref('org_market_entry_exit') }}
),

-- Market concentration context
concentration as (
    select
        micro_market,
        ahca_category,
        period_month,
        org_count as market_org_count,
        hhi_revenue as market_hhi,
        market_structure,
        top1_share as market_top1_share,
        top3_combined_share as market_top3_share,
        effective_competitors
    from {{ ref('micro_market_concentration') }}
),

-- Org taxonomy rate index (avg across taxonomies for this org × month)
tax_index as (
    select
        org_slug,
        period_month,
        avg(rpb_index) as avg_taxonomy_rpb_index,
        avg(rpc_index) as avg_taxonomy_rpc_index,
        avg(revenue_per_provider_index) as avg_taxonomy_rev_per_provider_index,
        count(distinct taxonomy_code) as taxonomy_count
    from {{ ref('org_taxonomy_profile') }}
    group by 1, 2
),

-- Pass 1: join all features
joined as (
    select
        -- === IDENTIFIERS ===
        t.org_slug,
        t.micro_market,
        t.ahca_category,
        t.period_month,
        t.period_year,

        -- === CURRENT STATE ===
        t.revenue_share,
        t.bene_share,
        t.claim_share,
        t.total_paid,
        t.total_beneficiaries,
        t.mkt_paid,

        -- === MOM TARGETS (1-month) ===
        t.rev_share_chg_1m_pp,
        t.bene_share_chg_1m_pp,
        t.rev_share_chg_1m_pct,
        t.rev_growth_1m_pct,
        t.mkt_growth_1m_pct,
        t.displacement_label_1m,
        t.displacement_dir_1m,

        -- === 3-MONTH TARGETS ===
        t.rev_share_chg_3m_pp,
        t.bene_share_chg_3m_pp,
        t.rev_share_chg_3m_pct,
        t.rev_growth_3m_pct,
        t.mkt_growth_3m_pct,
        t.displacement_label_3m,
        t.displacement_dir_3m,

        -- === 12-MONTH TARGETS (where available) ===
        t.rev_share_chg_12m_pp,
        t.bene_share_chg_12m_pp,
        t.rev_share_chg_12m_pct,
        t.rev_growth_12m_pct,
        t.mkt_growth_12m_pct,

        -- === FORWARD TARGETS (what ML predicts) ===
        t.rev_share_chg_next_3m_pp,
        t.bene_share_chg_next_3m_pp,

        -- === LAGGED SHARE (features) ===
        t.rev_share_1m_ago,
        t.bene_share_1m_ago,
        t.rev_share_3m_ago,
        t.bene_share_3m_ago,
        t.rev_share_12m_ago,
        t.bene_share_12m_ago,

        -- === DATA AVAILABILITY FLAGS ===
        t.has_1m_prior,
        t.has_3m_prior,
        t.has_12m_prior,
        t.has_3m_forward,

        -- === ORG SCALE FEATURES ===
        om.is_solo_practitioner,
        om.servicing_npi_count,
        om.active_codes,
        om.org_total_paid,
        om.org_total_benes,
        om.org_rpb,
        om.org_rpc,
        om.org_revenue_per_provider,

        -- === ORG GEOGRAPHIC FEATURES ===
        op.zip_count,
        op.pct_revenue_urban,
        op.pct_revenue_rural,
        op.pct_revenue_desert,
        op.pct_revenue_shortage,
        op.weighted_avg_market_share as org_weighted_market_share,
        op.market_type as org_market_type,
        op.operating_footprint,

        -- === ORG WORKFORCE FEATURES ===
        w.total_providers,
        w.psychiatrist_pct,
        w.counselor_pct,
        w.social_worker_pct,
        w.psychologist_pct,
        w.aprn_pct,
        w.sud_specialist_pct,
        w.workforce_category_count,
        w.dominant_workforce_type,

        -- === RATE INDEX FEATURES ===
        rp.category_rate_index,
        rp.category_rpb_index,
        rp.category_rpc_index,
        ti.avg_taxonomy_rpb_index,
        ti.avg_taxonomy_rpc_index,
        ti.avg_taxonomy_rev_per_provider_index,
        ti.taxonomy_count,

        -- === SERVICE MIX FEATURES ===
        sm.offers_service,

        -- === ENTRY/EXIT FEATURES ===
        ee.months_since_entry,
        ee.tenure_stage,
        ee.is_first_month,
        ee.is_returning,
        ee.is_entering,
        ee.is_last_observed_month,
        ee.is_continuously_active,

        -- === MARKET CONTEXT FEATURES ===
        c.market_org_count,
        c.market_hhi,
        c.market_structure,
        c.market_top1_share,
        c.market_top3_share,
        c.effective_competitors,

        -- === PROFIT POOL INDEX (share × rate) ===
        -- Captures: "what fraction of the profit pool are you capturing,
        -- adjusted for whether you're being paid above or below market?"
        -- High PPI = large share at good rates (true profit pool capture)
        -- Low PPI = small share or buying share at below-market rates
        t.revenue_share * coalesce(rp.category_rate_index, 1.0) as profit_pool_index,

        -- === COMPONENT SCORES (0-1 scale for each dimension) ===

        -- 1. Share momentum: 3m share change, clamped to [-0.1, +0.1] → [0, 1]
        least(greatest(coalesce(t.rev_share_chg_3m_pp, 0) / 0.1, -1.0), 1.0) * 0.5 + 0.5
            as share_momentum_score,

        -- 2. Rate viability: rate_index clamped [0.5, 1.5] → [0, 1]
        -- 1.0 = market rate = 0.5 score; >1.0 = above market = higher score
        least(greatest(coalesce(rp.category_rate_index, 1.0), 0.5), 1.5) / 1.5
            as rate_viability_score,

        -- 3. Stability: tenure months capped at 60 → [0.05, 1]
        -- Floor at 0.05 so first-month entrants aren't zeroed out in geometric mean
        greatest(least(coalesce(ee.months_since_entry, 0), 60) / 60.0, 0.05)
            as stability_score,

        -- 4. Market attractiveness: market growth 3m, clamped [-0.2, +0.2] → [0, 1]
        least(greatest(coalesce(t.mkt_growth_3m_pct, 0) / 0.2, -1.0), 1.0) * 0.5 + 0.5
            as market_attractiveness_score

    from targets t

-- Org monthly
left join org_monthly om
    on om.org_slug = t.org_slug
    and om.period_month = t.period_month

-- Org geographic profile
left join org_profile op
    on op.org_slug = t.org_slug
    and op.period_month = t.period_month

-- Workforce
left join workforce w
    on w.org_slug = t.org_slug
    and w.period_month = t.period_month

-- Rate profile for this category
left join rate_profile rp
    on rp.org_slug = t.org_slug
    and rp.ahca_category = t.ahca_category
    and rp.period_month = t.period_month

-- Service mix
left join service_mix sm
    on sm.org_slug = t.org_slug
    and sm.ahca_category = t.ahca_category
    and sm.period_month = t.period_month

-- Entry/exit
left join entry_exit ee
    on ee.org_slug = t.org_slug
    and ee.micro_market = t.micro_market
    and ee.ahca_category = t.ahca_category
    and ee.period_month = t.period_month

-- Market concentration
left join concentration c
    on c.micro_market = t.micro_market
    and c.ahca_category = t.ahca_category
    and c.period_month = t.period_month

-- Taxonomy index
    left join tax_index ti
        on ti.org_slug = t.org_slug
        and ti.period_month = t.period_month
)

-- Pass 2: window functions on profit pool index + composite outpace score
select
    j.*,

    -- Profit pool index lags
    lag(j.profit_pool_index, 1) over w as ppi_1m_ago,
    lag(j.profit_pool_index, 3) over w as ppi_3m_ago,

    -- Profit pool index change (the core target)
    j.profit_pool_index - lag(j.profit_pool_index, 1) over w as ppi_chg_1m,
    j.profit_pool_index - lag(j.profit_pool_index, 3) over w as ppi_chg_3m,

    -- Forward profit pool (what ML predicts)
    lead(j.profit_pool_index, 3) over w as ppi_3m_ahead,
    lead(j.profit_pool_index, 3) over w - j.profit_pool_index as ppi_chg_next_3m,

    -- === OUTPACE COMPOSITE ===
    -- Geometric mean of the 4 component scores (0-1 range)
    -- Geometric mean penalizes any single weak dimension heavily
    pow(
        j.share_momentum_score
        * j.rate_viability_score
        * j.stability_score
        * j.market_attractiveness_score,
        0.25
    ) as outpace_score,

    -- Outpace label based on composite score
    case
        when pow(j.share_momentum_score * j.rate_viability_score
                 * j.stability_score * j.market_attractiveness_score, 0.25) >= 0.7
            then 'capturing'      -- strong on all 4 dimensions
        when pow(j.share_momentum_score * j.rate_viability_score
                 * j.stability_score * j.market_attractiveness_score, 0.25) >= 0.5
            then 'defending'      -- solid but not exceptional
        when pow(j.share_momentum_score * j.rate_viability_score
                 * j.stability_score * j.market_attractiveness_score, 0.25) >= 0.35
            then 'vulnerable'     -- one or more dimensions weak
        else 'retreating'         -- multiple dimensions failing
    end as outpace_label,

    -- Forward outpace: will the outpace_score improve in 3 months?
    lead(
        pow(j.share_momentum_score * j.rate_viability_score
            * j.stability_score * j.market_attractiveness_score, 0.25),
        3
    ) over w as outpace_score_3m_ahead

from joined j
window w as (partition by j.org_slug, j.micro_market, j.ahca_category order by j.period_month)
