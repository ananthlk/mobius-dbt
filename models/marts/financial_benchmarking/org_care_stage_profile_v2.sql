{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Long-format care-stage profile per org-year. Unpivots the existing
-- intake_/high_acuity_/ongoing_ columns on org_kpis_v2 into one row per
-- (org_slug, period_year, care_stage). Downstream endpoints and benchmark
-- joins become straightforward: filter by care_stage instead of picking
-- specific columns.
--
-- Grain: org_slug × period_year × care_stage  (3 rows per org-year)
--
-- Per-stage metrics:
--   total_paid            — raw dollars for this stage
--   total_claims          — raw claim count for this stage
--   total_benes           — raw unique beneficiary count for this stage
--   revenue_pct           — share of this org-year's paid in this stage (0..1)
--   bene_pct              — share of this org-year's benes in this stage (0..1)
--   local_market_share    — org's stage_paid / total stage_paid in same ZIP
--   payment_per_claim     — Σpaid/Σclaims at this (org, stage, year)
--   claims_per_bene       — Σclaims/Σbenes
--   revenue_per_bene      — Σpaid/Σbenes
--
-- Org-level passthroughs (for filter joins, avoids re-joining org_kpis_v2):
--   org_name, org_type, size_band, market_tier, org_state, org_zip5,
--   panel_size, total_paid_all_stages

with src as (
    select
        org_slug, org_name, org_state, org_zip5, org_city,
        org_type, size_band, market_tier, period_year,
        panel_size,
        total_paid as total_paid_all_stages,

        intake_paid, intake_claims, intake_benes,
        intake_revenue_pct, intake_bene_pct, intake_market_share,

        high_acuity_paid, high_acuity_claims, high_acuity_benes,
        high_acuity_revenue_pct, high_acuity_bene_pct, high_acuity_market_share,

        ongoing_paid, ongoing_claims, ongoing_benes,
        ongoing_revenue_pct, ongoing_bene_pct, ongoing_market_share
    from {{ ref('org_kpis_v2') }}
),

intake as (
    select
        org_slug, org_name, org_state, org_zip5, org_city,
        org_type, size_band, market_tier, period_year,
        panel_size, total_paid_all_stages,
        'intake'                 as care_stage,
        intake_paid              as total_paid,
        intake_claims            as total_claims,
        intake_benes             as total_benes,
        intake_revenue_pct       as revenue_pct,
        intake_bene_pct          as bene_pct,
        intake_market_share      as local_market_share
    from src
),

high_acuity as (
    select
        org_slug, org_name, org_state, org_zip5, org_city,
        org_type, size_band, market_tier, period_year,
        panel_size, total_paid_all_stages,
        'high_acuity'            as care_stage,
        high_acuity_paid         as total_paid,
        high_acuity_claims       as total_claims,
        high_acuity_benes        as total_benes,
        high_acuity_revenue_pct  as revenue_pct,
        high_acuity_bene_pct     as bene_pct,
        high_acuity_market_share as local_market_share
    from src
),

ongoing as (
    select
        org_slug, org_name, org_state, org_zip5, org_city,
        org_type, size_band, market_tier, period_year,
        panel_size, total_paid_all_stages,
        'ongoing_treatment'      as care_stage,
        ongoing_paid             as total_paid,
        ongoing_claims           as total_claims,
        ongoing_benes            as total_benes,
        ongoing_revenue_pct      as revenue_pct,
        ongoing_bene_pct         as bene_pct,
        ongoing_market_share     as local_market_share
    from src
),

unioned as (
    select * from intake
    union all
    select * from high_acuity
    union all
    select * from ongoing
)

select
    org_slug, org_name, org_state, org_zip5, org_city,
    org_type, size_band, market_tier, period_year, care_stage,
    panel_size, total_paid_all_stages,
    total_paid, total_claims, total_benes,
    revenue_pct, bene_pct, local_market_share,
    safe_divide(total_paid,   total_claims) as payment_per_claim,
    safe_divide(total_claims, total_benes)  as claims_per_bene,
    safe_divide(total_paid,   total_benes)  as revenue_per_bene
from unioned
