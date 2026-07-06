{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Consolidated org profile: everything about an org in one row.
-- Joins org_kpis_v2 (KPIs + care spectrum + clinician mix)
--       + org_leakage_v2 (catchment market share / leakage)
--       + org_peer_distributions_v2 (peer P50 for relative positioning)
-- Plus derived flags: new entrant, growth trajectory, care focus.
--
-- Grain: org_slug × period_year.
-- Consumer: single API endpoint → chat, dashboards, reports.

with kpis as (
    select *
    from {{ ref('org_kpis_v2') }}
    qualify row_number() over (
        partition by org_slug, period_year
        order by total_paid desc
    ) = 1
),

-- Leakage & peer distributions are periodic tables.
-- Direct BQ references (not ref()) to avoid the enabled=false gate.
{% set fin_ds = env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev') %}
{% set bq_project = env_var('BQ_PROJECT', 'mobius-os-dev') %}

leakage as (
    select
        org_slug,
        cast(period_year as string) as period_year,
        catchment_zip_count,
        org_claims       as catchment_org_claims,
        org_paid         as catchment_org_paid,
        org_benes        as catchment_org_benes,
        catchment_claims as catchment_total_claims,
        catchment_paid   as catchment_total_paid,
        catchment_benes  as catchment_total_benes,
        catchment_npis   as catchment_total_npis,
        org_npis_in_catchment,
        market_share_claims as catchment_market_share_claims,
        market_share_paid   as catchment_market_share_paid,
        leakage_claims      as catchment_leakage_claims,
        leakage_paid        as catchment_leakage_paid
    from `{{ bq_project }}.{{ fin_ds }}.org_leakage_v2`
),

-- org_peer_distributions_v2 is periodic; read directly from BQ.
peer_benchmarks as (
    select
        org_type,
        period_year,
        p50_panel_per_clin,
        p50_claims_per_bene,
        p50_payment_per_claim,
        mean_market_share        as peer_mean_market_share,
        mean_intake_bene_pct     as peer_mean_intake_bene_pct,
        mean_high_acuity_bene_pct as peer_mean_high_acuity_bene_pct,
        mean_ongoing_bene_pct    as peer_mean_ongoing_bene_pct
    from `{{ bq_project }}.{{ fin_ds }}.org_peer_distributions_v2`
    where peer_group = 'type_only'
      and geo_level  = 'national'
),

-- Derived flags that need multi-year context
with_flags as (
    select
        k.*,

        -- ── Entrant detection ──
        min(k.period_year) over (partition by k.org_slug) as first_claim_year,
        case
            when min(k.period_year) over (partition by k.org_slug) >= '2022' then true
            else false
        end as is_new_entrant,

        -- ── Growth trajectory (YoY revenue) ──
        lag(k.total_paid) over (
            partition by k.org_slug order by k.period_year
        ) as prior_year_paid,
        lag(k.panel_size) over (
            partition by k.org_slug order by k.period_year
        ) as prior_year_benes,

        -- ── Care focus (dominant tier by benes) ──
        case
            when k.intake_bene_pct     > 0.40 then 'intake_heavy'
            when k.high_acuity_bene_pct > 0.20 then 'acute_heavy'
            when k.ongoing_bene_pct    > 0.90 then 'ongoing_only'
            else 'balanced'
        end as care_focus

    from kpis k
)

select
    -- ══════════════════════════════════════════════════════
    -- IDENTITY
    -- ══════════════════════════════════════════════════════
    f.org_slug,
    f.org_name,
    f.org_state,
    f.org_zip5,
    f.org_city,
    f.primary_taxonomy_code,
    f.billing_npi_count,
    f.org_type,
    f.cmhc_tier,
    f.market_tier,
    f.size_band,
    f.period_year,

    -- ══════════════════════════════════════════════════════
    -- FLAGS (derived)
    -- ══════════════════════════════════════════════════════
    f.first_claim_year,
    f.is_new_entrant,
    f.care_focus,

    case
        when f.prior_year_paid is null then 'new'
        when safe_divide(f.total_paid - f.prior_year_paid, f.prior_year_paid) >  0.10 then 'growing'
        when safe_divide(f.total_paid - f.prior_year_paid, f.prior_year_paid) < -0.10 then 'declining'
        else 'stable'
    end as growth_trajectory,

    round(safe_divide(f.total_paid - f.prior_year_paid, f.prior_year_paid), 4)  as revenue_growth_pct,
    round(safe_divide(
        cast(f.panel_size as float64) - cast(f.prior_year_benes as float64),
        cast(f.prior_year_benes as float64)
    ), 4) as bene_growth_pct,

    -- Relative positioning vs peer P50
    case
        when f.payment_per_claim > pb.p50_payment_per_claim then 'above_p50'
        else 'below_p50'
    end as rate_position,

    case
        when f.panel_per_clinician > pb.p50_panel_per_clin then 'lean'
        else 'heavy'
    end as panel_efficiency,

    -- ══════════════════════════════════════════════════════
    -- SCALE METRICS
    -- ══════════════════════════════════════════════════════
    f.servicing_npi_count,
    f.panel_size,
    f.total_claims,
    f.total_paid,

    -- ══════════════════════════════════════════════════════
    -- UNIT ECONOMICS
    -- ══════════════════════════════════════════════════════
    f.panel_per_clinician,
    f.claims_per_beneficiary,
    f.payment_per_claim,
    safe_divide(f.total_paid, f.panel_size) as revenue_per_bene,

    -- Peer P50 for context
    pb.p50_panel_per_clin     as peer_p50_panel_per_clin,
    pb.p50_claims_per_bene    as peer_p50_claims_per_bene,
    pb.p50_payment_per_claim  as peer_p50_payment_per_claim,

    -- ══════════════════════════════════════════════════════
    -- CLINICIAN MIX
    -- ══════════════════════════════════════════════════════
    f.psychiatry_count,
    f.counselor_count,
    f.social_worker_count,
    f.mft_count,
    f.psychologist_count,
    f.aprn_count,
    f.other_clinician_count,
    f.psychiatry_pct,
    f.counselor_pct,
    f.social_worker_pct,
    f.mft_pct,
    f.psychologist_pct,
    f.aprn_pct,

    -- ══════════════════════════════════════════════════════
    -- CARE SPECTRUM
    -- ══════════════════════════════════════════════════════
    f.intake_paid,
    f.high_acuity_paid,
    f.ongoing_paid,
    f.intake_claims,
    f.high_acuity_claims,
    f.ongoing_claims,
    f.intake_benes,
    f.high_acuity_benes,
    f.ongoing_benes,

    -- Market share per tier (ZIP-level)
    f.market_share_pct,
    f.intake_market_share,
    f.high_acuity_market_share,
    f.ongoing_market_share,

    -- Revenue & bene mix
    f.intake_revenue_pct,
    f.high_acuity_revenue_pct,
    f.ongoing_revenue_pct,
    f.intake_bene_pct,
    f.high_acuity_bene_pct,
    f.ongoing_bene_pct,

    -- ══════════════════════════════════════════════════════
    -- CATCHMENT / LEAKAGE
    -- ══════════════════════════════════════════════════════
    l.catchment_zip_count,
    l.catchment_org_paid,
    l.catchment_total_paid,
    l.catchment_market_share_paid,
    l.catchment_leakage_paid,
    l.catchment_org_benes,
    l.catchment_total_benes,
    l.catchment_market_share_claims,
    l.catchment_leakage_claims,
    l.catchment_total_npis,
    l.org_npis_in_catchment

from with_flags f
left join leakage l
    on  l.org_slug    = f.org_slug
    and l.period_year = f.period_year
left join peer_benchmarks pb
    on  pb.org_type    = f.org_type
    and pb.period_year = f.period_year
