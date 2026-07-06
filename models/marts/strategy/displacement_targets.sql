{{
  config(
    materialized='table',
  )
}}

-- Displacement Targets
-- Grain: one row per org_slug × micro_market × ahca_category × period_month.
-- Computes MoM and 3-month share change targets for the displacement ML model.
-- Uses LAG windows instead of self-joins for efficiency.
-- No prior-year requirement — preserves all rows including new entrants.

with base as (
    select
        org_slug,
        micro_market,
        ahca_category,
        period_month,
        period_year,
        total_paid,
        total_beneficiaries,
        total_claims,
        revenue_share,
        bene_share,
        claim_share,
        mkt_paid,
        mkt_beneficiaries,
        mkt_claims
    from {{ ref('org_micro_market_share') }}
),

with_lags as (
    select
        *,

        -- 1-month lag (MoM)
        lag(revenue_share, 1) over w as rev_share_1m_ago,
        lag(bene_share, 1) over w    as bene_share_1m_ago,
        lag(total_paid, 1) over w    as paid_1m_ago,
        lag(mkt_paid, 1) over w      as mkt_paid_1m_ago,

        -- 3-month lag
        lag(revenue_share, 3) over w as rev_share_3m_ago,
        lag(bene_share, 3) over w    as bene_share_3m_ago,
        lag(total_paid, 3) over w    as paid_3m_ago,
        lag(mkt_paid, 3) over w      as mkt_paid_3m_ago,

        -- 12-month lag (YoY — available when data exists, not required)
        lag(revenue_share, 12) over w as rev_share_12m_ago,
        lag(bene_share, 12) over w    as bene_share_12m_ago,
        lag(total_paid, 12) over w    as paid_12m_ago,
        lag(mkt_paid, 12) over w      as mkt_paid_12m_ago,

        -- Forward look: 3-month ahead share (for predicting future displacement)
        lead(revenue_share, 3) over w as rev_share_3m_ahead,
        lead(bene_share, 3) over w    as bene_share_3m_ahead

    from base
    window w as (partition by org_slug, micro_market, ahca_category order by period_month)
)

select
    org_slug,
    micro_market,
    ahca_category,
    period_month,
    period_year,

    -- Current state
    total_paid,
    total_beneficiaries,
    total_claims,
    revenue_share,
    bene_share,
    claim_share,
    mkt_paid,

    -- === MOM TARGETS (1-month) ===
    revenue_share - rev_share_1m_ago as rev_share_chg_1m_pp,
    bene_share - bene_share_1m_ago   as bene_share_chg_1m_pp,
    safe_divide(revenue_share - rev_share_1m_ago, rev_share_1m_ago) as rev_share_chg_1m_pct,
    safe_divide(total_paid - paid_1m_ago, paid_1m_ago) as rev_growth_1m_pct,
    safe_divide(mkt_paid - mkt_paid_1m_ago, mkt_paid_1m_ago) as mkt_growth_1m_pct,

    -- === 3-MONTH TARGETS ===
    revenue_share - rev_share_3m_ago as rev_share_chg_3m_pp,
    bene_share - bene_share_3m_ago   as bene_share_chg_3m_pp,
    safe_divide(revenue_share - rev_share_3m_ago, rev_share_3m_ago) as rev_share_chg_3m_pct,
    safe_divide(total_paid - paid_3m_ago, paid_3m_ago) as rev_growth_3m_pct,
    safe_divide(mkt_paid - mkt_paid_3m_ago, mkt_paid_3m_ago) as mkt_growth_3m_pct,

    -- === 12-MONTH TARGETS (available when history exists) ===
    revenue_share - rev_share_12m_ago as rev_share_chg_12m_pp,
    bene_share - bene_share_12m_ago   as bene_share_chg_12m_pp,
    safe_divide(revenue_share - rev_share_12m_ago, rev_share_12m_ago) as rev_share_chg_12m_pct,
    safe_divide(total_paid - paid_12m_ago, paid_12m_ago) as rev_growth_12m_pct,
    safe_divide(mkt_paid - mkt_paid_12m_ago, mkt_paid_12m_ago) as mkt_growth_12m_pct,

    -- === FORWARD TARGETS (what ML predicts) ===
    rev_share_3m_ahead - revenue_share as rev_share_chg_next_3m_pp,
    bene_share_3m_ahead - bene_share   as bene_share_chg_next_3m_pp,

    -- === MOM LABELS ===
    case
        when rev_share_1m_ago is null then 'new'
        when revenue_share - rev_share_1m_ago > 0.02 then 'strong_gainer'
        when revenue_share - rev_share_1m_ago > 0.005 then 'gainer'
        when revenue_share - rev_share_1m_ago > -0.005 then 'stable'
        when revenue_share - rev_share_1m_ago > -0.02 then 'loser'
        else 'strong_loser'
    end as displacement_label_1m,

    -- === 3-MONTH LABELS ===
    case
        when rev_share_3m_ago is null then 'new'
        when revenue_share - rev_share_3m_ago > 0.03 then 'strong_gainer'
        when revenue_share - rev_share_3m_ago > 0.01 then 'gainer'
        when revenue_share - rev_share_3m_ago > -0.01 then 'stable'
        when revenue_share - rev_share_3m_ago > -0.03 then 'loser'
        else 'strong_loser'
    end as displacement_label_3m,

    -- === BINARY DIRECTION ===
    case
        when rev_share_1m_ago is null then null
        when revenue_share - rev_share_1m_ago > 0.005 then 1
        when revenue_share - rev_share_1m_ago < -0.005 then -1
        else 0
    end as displacement_dir_1m,

    case
        when rev_share_3m_ago is null then null
        when revenue_share - rev_share_3m_ago > 0.01 then 1
        when revenue_share - rev_share_3m_ago < -0.01 then -1
        else 0
    end as displacement_dir_3m,

    -- === DATA AVAILABILITY FLAGS ===
    rev_share_1m_ago is not null as has_1m_prior,
    rev_share_3m_ago is not null as has_3m_prior,
    rev_share_12m_ago is not null as has_12m_prior,
    rev_share_3m_ahead is not null as has_3m_forward,

    -- === LAGGED VALUES (features for ML) ===
    rev_share_1m_ago,
    bene_share_1m_ago,
    rev_share_3m_ago,
    bene_share_3m_ago,
    rev_share_12m_ago,
    bene_share_12m_ago

from with_lags
