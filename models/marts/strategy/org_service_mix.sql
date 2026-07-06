{{
  config(
    materialized='table',
  )
}}

-- Org Service Mix
-- Grain: one row per org_slug × ahca_category × period_month.
-- For every org × month, crosses ALL 22 ahca categories and flags
-- whether the org billed in that category (offers = true) or not (offers = false).
-- Enables ML to distinguish "no rate because doesn't offer" from "offers but no claims this month."

with all_categories as (
    select distinct ahca_category
    from {{ ref('stg_bh_codes') }}
),

-- All org × month combos that had any activity
org_months as (
    select distinct org_slug, period_month, period_year
    from {{ ref('org_market_monthly') }}
),

-- Cross join: every org × month × category
spine as (
    select
        om.org_slug,
        om.period_month,
        om.period_year,
        ac.ahca_category
    from org_months om
    cross join all_categories ac
),

-- Actual activity from org_rate_profile
activity as (
    select
        org_slug,
        ahca_category,
        period_month,
        total_beneficiaries,
        total_claims,
        total_paid,
        rate_index
    from {{ ref('org_rate_profile') }}
)

select
    s.org_slug,
    s.period_month,
    s.period_year,
    s.ahca_category,
    case when a.org_slug is not null then true else false end as offers_service,
    coalesce(a.total_beneficiaries, 0) as total_beneficiaries,
    coalesce(a.total_claims, 0)        as total_claims,
    coalesce(a.total_paid, 0)          as total_paid,
    a.rate_index
from spine s
left join activity a
    on a.org_slug = s.org_slug
    and a.ahca_category = s.ahca_category
    and a.period_month = s.period_month
