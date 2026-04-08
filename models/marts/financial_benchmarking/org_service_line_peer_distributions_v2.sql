{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
    tags=['periodic'],
    enabled=var('run_periodic', false),
  )
}}

-- Service-line-aware org peer distribution statistics — v2.
-- Uses credentialing-deduped org identity (org_service_line_kpis_v2 / org_slug).
-- One row per org_type × service_line × peer_group × size_band × market_tier × geo_level × geo_id × period_year.
--
-- Extends org_peer_distributions_v2 by adding a service_line dimension.
-- This enables fair benchmarking: compare an org's outpatient therapy arm
-- against peers' outpatient therapy arms — not their ACT or residential arms.
--
-- peer_group logic mirrors org_peer_distributions:
--   'type_only'        — org_type + service_line (widest)
--   'type_size'        — org_type + service_line + size_band
--   'type_size_market' — org_type + service_line + size_band + market_tier (tightest)
--
-- size_band is computed at the service-line level (panel_per_clinician for that service line only).
-- Geo levels: national and state only (zip omitted — too sparse with service line added).
-- Minimum n = 3.

with base as (
    select
        org_slug,
        period_year,
        org_type,
        service_line,
        market_tier,
        size_band,
        org_state,
        panel_per_clinician,
        servicing_npi_count,
        claims_per_beneficiary,
        payment_per_claim
    from {{ ref('org_service_line_kpis_v2') }}
    where org_type              != 'OTHER'
      and panel_per_clinician    is not null
      and panel_per_clinician    >  0
      and claims_per_beneficiary is not null
      and payment_per_claim      is not null
),

-- ── type_only — org_type + service_line (no size or market filter) ────────────

to_national as (
    select
        org_type, service_line, 'type_only' as peer_group,
        cast(null as string) as size_band, cast(null as string) as market_tier,
        'national' as geo_level, 'US' as geo_id, period_year,
        count(distinct org_slug)                               as n,
        avg(panel_per_clinician)                                    as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]        as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]        as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]        as p75_panel_per_clin,
        stddev(panel_per_clinician)                                 as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                   as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]        as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]        as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]        as p75_clinician_count,
        avg(claims_per_beneficiary)                                 as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]     as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]     as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]     as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                              as std_claims_per_bene,
        avg(payment_per_claim)                                      as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]          as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]          as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]          as p75_payment_per_claim,
        stddev(payment_per_claim)                                   as std_payment_per_claim
    from base
    group by org_type, service_line, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_slug) >= 3
),

to_state as (
    select
        org_type, service_line, 'type_only' as peer_group,
        cast(null as string) as size_band, cast(null as string) as market_tier,
        'state' as geo_level, org_state as geo_id, period_year,
        count(distinct org_slug)                               as n,
        avg(panel_per_clinician)                                    as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]        as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]        as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]        as p75_panel_per_clin,
        stddev(panel_per_clinician)                                 as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                   as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]        as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]        as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]        as p75_clinician_count,
        avg(claims_per_beneficiary)                                 as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]     as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]     as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]     as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                              as std_claims_per_bene,
        avg(payment_per_claim)                                      as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]          as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]          as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]          as p75_payment_per_claim,
        stddev(payment_per_claim)                                   as std_payment_per_claim
    from base where org_state != ''
    group by org_type, service_line, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_slug) >= 3
),

-- ── type_size — org_type + service_line + size_band ───────────────────────────

ts_national as (
    select
        org_type, service_line, 'type_size' as peer_group,
        size_band, cast(null as string) as market_tier,
        'national' as geo_level, 'US' as geo_id, period_year,
        count(distinct org_slug)                               as n,
        avg(panel_per_clinician)                                    as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]        as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]        as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]        as p75_panel_per_clin,
        stddev(panel_per_clinician)                                 as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                   as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]        as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]        as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]        as p75_clinician_count,
        avg(claims_per_beneficiary)                                 as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]     as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]     as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]     as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                              as std_claims_per_bene,
        avg(payment_per_claim)                                      as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]          as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]          as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]          as p75_payment_per_claim,
        stddev(payment_per_claim)                                   as std_payment_per_claim
    from base where size_band is not null
    group by org_type, service_line, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_slug) >= 3
),

ts_state as (
    select
        org_type, service_line, 'type_size' as peer_group,
        size_band, cast(null as string) as market_tier,
        'state' as geo_level, org_state as geo_id, period_year,
        count(distinct org_slug)                               as n,
        avg(panel_per_clinician)                                    as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]        as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]        as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]        as p75_panel_per_clin,
        stddev(panel_per_clinician)                                 as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                   as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]        as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]        as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]        as p75_clinician_count,
        avg(claims_per_beneficiary)                                 as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]     as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]     as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]     as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                              as std_claims_per_bene,
        avg(payment_per_claim)                                      as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]          as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]          as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]          as p75_payment_per_claim,
        stddev(payment_per_claim)                                   as std_payment_per_claim
    from base where size_band is not null and org_state != ''
    group by org_type, service_line, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_slug) >= 3
),

-- ── type_size_market — org_type + service_line + size_band + market_tier ──────

tsm_national as (
    select
        org_type, service_line, 'type_size_market' as peer_group,
        size_band, market_tier,
        'national' as geo_level, 'US' as geo_id, period_year,
        count(distinct org_slug)                               as n,
        avg(panel_per_clinician)                                    as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]        as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]        as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]        as p75_panel_per_clin,
        stddev(panel_per_clinician)                                 as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                   as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]        as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]        as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]        as p75_clinician_count,
        avg(claims_per_beneficiary)                                 as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]     as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]     as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]     as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                              as std_claims_per_bene,
        avg(payment_per_claim)                                      as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]          as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]          as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]          as p75_payment_per_claim,
        stddev(payment_per_claim)                                   as std_payment_per_claim
    from base where size_band is not null and market_tier is not null
    group by org_type, service_line, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_slug) >= 3
),

tsm_state as (
    select
        org_type, service_line, 'type_size_market' as peer_group,
        size_band, market_tier,
        'state' as geo_level, org_state as geo_id, period_year,
        count(distinct org_slug)                               as n,
        avg(panel_per_clinician)                                    as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]        as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]        as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]        as p75_panel_per_clin,
        stddev(panel_per_clinician)                                 as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                   as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]        as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]        as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]        as p75_clinician_count,
        avg(claims_per_beneficiary)                                 as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]     as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]     as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]     as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                              as std_claims_per_bene,
        avg(payment_per_claim)                                      as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]          as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]          as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]          as p75_payment_per_claim,
        stddev(payment_per_claim)                                   as std_payment_per_claim
    from base where size_band is not null and market_tier is not null and org_state != ''
    group by org_type, service_line, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_slug) >= 3
)

select * from to_national
union all select * from to_state
union all select * from ts_national
union all select * from ts_state
union all select * from tsm_national
union all select * from tsm_state
