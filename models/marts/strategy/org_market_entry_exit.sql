{{
  config(
    materialized='table',
  )
}}

-- Org Market Entry/Exit
-- Grain: one row per org_slug × micro_market × ahca_category × period_month.
-- Flags each org-month as new entrant, incumbent, or exiting within each
-- micro-market × service category. Uses 3-month lookback (consistent with
-- taxonomy_churn_monthly) to handle PTO/data lags.

with activity as (
    select
        org_slug,
        micro_market,
        ahca_category,
        period_month,
        period_year,
        total_paid,
        total_beneficiaries,
        revenue_share,
        bene_share
    from {{ ref('org_micro_market_share') }}
),

-- First and last active month per org × micro-market × category
boundaries as (
    select
        org_slug,
        micro_market,
        ahca_category,
        min(period_month) as first_active_month,
        max(period_month) as last_active_month
    from activity
    group by 1, 2, 3
),

-- For entry/exit classification with 3-month lookback
with_context as (
    select
        a.org_slug,
        a.micro_market,
        a.ahca_category,
        a.period_month,
        a.period_year,
        a.total_paid,
        a.total_beneficiaries,
        a.revenue_share,
        a.bene_share,
        b.first_active_month,
        b.last_active_month,

        -- Was active in any of prior 3 months?
        max(case when a2.period_month is not null then 1 else 0 end) as had_prior_3m_activity

    from activity a
    inner join boundaries b
        on b.org_slug = a.org_slug
        and b.micro_market = a.micro_market
        and b.ahca_category = a.ahca_category
    left join activity a2
        on a2.org_slug = a.org_slug
        and a2.micro_market = a.micro_market
        and a2.ahca_category = a.ahca_category
        and a2.period_month < a.period_month
        and a2.period_month >= format_date('%Y-%m', date_sub(parse_date('%Y-%m', a.period_month), interval 3 month))
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
)

select
    org_slug,
    micro_market,
    ahca_category,
    period_month,
    period_year,
    total_paid,
    total_beneficiaries,
    revenue_share,
    bene_share,

    first_active_month,
    last_active_month,

    -- Months since first entry into this micro-market × category
    date_diff(
        parse_date('%Y-%m', period_month),
        parse_date('%Y-%m', first_active_month),
        month
    ) as months_since_entry,

    -- Tenure bucket
    case
        when date_diff(parse_date('%Y-%m', period_month), parse_date('%Y-%m', first_active_month), month) <= 3
            then 'new_entrant'
        when date_diff(parse_date('%Y-%m', period_month), parse_date('%Y-%m', first_active_month), month) <= 12
            then 'early_stage'
        when date_diff(parse_date('%Y-%m', period_month), parse_date('%Y-%m', first_active_month), month) <= 36
            then 'established'
        else 'veteran'
    end as tenure_stage,

    -- Entry flags
    period_month = first_active_month as is_first_month,
    had_prior_3m_activity = 0 and period_month != first_active_month as is_returning,
    had_prior_3m_activity = 0 as is_entering,  -- first month OR returning after gap

    -- Exit detection: is this the last month we see them?
    -- (only knowable after the fact — marks final observation)
    period_month = last_active_month as is_last_observed_month,

    -- Active streak: how many consecutive months active up to this point
    -- (approximate: count months in prior 12 that had activity)
    had_prior_3m_activity as is_continuously_active

from with_context
