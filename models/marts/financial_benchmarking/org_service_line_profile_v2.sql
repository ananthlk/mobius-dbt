{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Enriched service line profile: raw + ratios + decomposed + benchmarked.
-- Joins org_service_line_kpis_v2 (L1+L2)
--       + org_profile_v2 (org totals for share-of-org %)
--       + org_service_line_peer_distributions_v2 (peer P50 for indexing)
-- Plus derived: share of org, YoY growth, rate/util/panel index.
--
-- Grain: org_slug × service_line × period_year.
-- Consumer: API endpoints, chat, rate gap analysis.

{% set fin_ds = env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev') %}
{% set bq_project = env_var('BQ_PROJECT', 'mobius-os-dev') %}

-- org_service_line_kpis_v2 is periodic; direct BQ read.
-- Deduplicate: source may have multiple rows per grain from incremental builds.
with svc as (
    select *
    from `{{ bq_project }}.{{ fin_ds }}.org_service_line_kpis_v2`
    qualify row_number() over (
        partition by org_slug, service_line, period_year
        order by total_paid desc
    ) = 1
),

-- Org-level totals for computing share-of-org (also deduplicated)
org_totals as (
    select
        org_slug,
        period_year,
        total_paid     as org_total_paid,
        panel_size     as org_total_benes,
        total_claims   as org_total_claims
    from {{ ref('org_kpis_v2') }}
    where panel_size > 0 and total_claims > 0
    qualify row_number() over (
        partition by org_slug, period_year
        order by total_paid desc
    ) = 1
),

-- Peer P50 by org_type × service_line (periodic table — direct BQ read)
peer_benchmarks as (
    select
        org_type,
        service_line,
        period_year,
        p50_payment_per_claim,
        p50_claims_per_bene,
        p50_panel_per_clin,
        mean_payment_per_claim,
        mean_claims_per_bene,
        mean_panel_per_clin,
        n as peer_n
    from `{{ bq_project }}.{{ fin_ds }}.org_service_line_peer_distributions_v2`
    where peer_group = 'type_only'
      and geo_level  = 'national'
),

-- Add prior year for YoY growth
with_prior as (
    select
        s.*,
        lag(s.total_paid) over (
            partition by s.org_slug, s.service_line order by s.period_year
        ) as prior_year_paid,
        lag(s.panel_size) over (
            partition by s.org_slug, s.service_line order by s.period_year
        ) as prior_year_benes
    from svc s
)

select
    -- ── Identity (from service line kpis) ──
    w.org_slug,
    w.org_name,
    w.org_state,
    w.org_zip5,
    w.org_city,
    w.org_type,
    w.market_tier,
    w.period_year,
    w.service_line,

    -- ── L1: Raw counts ──
    w.servicing_npi_count,
    w.panel_size,
    w.total_claims,
    w.total_paid,

    -- ── L2: Simple ratios ──
    w.panel_per_clinician,
    w.claims_per_beneficiary,
    w.payment_per_claim,
    safe_divide(w.total_paid, w.panel_size) as revenue_per_bene,

    -- ── L3: Decomposed — share of org ──
    round(safe_divide(w.total_paid,   ot.org_total_paid),   4) as revenue_share_of_org,
    round(safe_divide(w.panel_size,   ot.org_total_benes),  4) as bene_share_of_org,
    round(safe_divide(w.total_claims, ot.org_total_claims), 4) as claims_share_of_org,

    -- ── L3: Decomposed — YoY growth ──
    case
        when w.prior_year_paid is null then 'new'
        when safe_divide(w.total_paid - w.prior_year_paid, w.prior_year_paid) >  0.10 then 'growing'
        when safe_divide(w.total_paid - w.prior_year_paid, w.prior_year_paid) < -0.10 then 'declining'
        else 'stable'
    end as svc_growth_trajectory,
    round(safe_divide(w.total_paid - w.prior_year_paid, w.prior_year_paid), 4) as svc_revenue_growth_pct,
    round(safe_divide(
        cast(w.panel_size as float64) - cast(w.prior_year_benes as float64),
        cast(w.prior_year_benes as float64)
    ), 4) as svc_bene_growth_pct,

    -- ── L4: Benchmarked — peer P50 context ──
    pb.peer_n,
    pb.p50_payment_per_claim  as peer_p50_rate,
    pb.p50_claims_per_bene    as peer_p50_util,
    pb.p50_panel_per_clin     as peer_p50_panel,

    -- ── L4: Benchmarked — indexes (org / P50) ──
    round(safe_divide(w.payment_per_claim,    pb.p50_payment_per_claim), 4) as rate_index,
    round(safe_divide(w.claims_per_beneficiary, pb.p50_claims_per_bene),  4) as util_index,
    round(safe_divide(w.panel_per_clinician,  pb.p50_panel_per_clin),    4) as panel_index,

    -- ── L4: Benchmarked — rate gap in dollars ──
    round(
        (w.payment_per_claim - coalesce(pb.p50_payment_per_claim, w.payment_per_claim))
        * w.total_claims,
    2) as rate_gap_dollars

from with_prior w
left join org_totals ot
    on  ot.org_slug    = w.org_slug
    and ot.period_year = w.period_year
left join peer_benchmarks pb
    on  pb.org_type     = w.org_type
    and pb.service_line = w.service_line
    and pb.period_year  = w.period_year
where w.total_claims > 0
