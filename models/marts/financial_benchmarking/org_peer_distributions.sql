{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Organization-to-organization peer distribution statistics.
-- One row per org_type × peer_group × size_band × market_tier × geo_level × geo_id × period_year.
--
-- peer_group encodes which stratification filters are applied:
--   'type_only'          — org_type match only (widest, highest n)
--   'type_size'          — org_type + size_band
--   'type_market'        — org_type + market_tier
--   'type_size_market'   — org_type + size_band + market_tier (tightest, most comparable)
--
-- The API selects the tightest peer_group with n >= 3, falling back toward wider groups.
-- size_band / market_tier are populated only when they are part of the filter; NULL otherwise.
--
-- KPI distributions: panel_per_clinician, servicing_npi_count, claims_per_bene, payment_per_claim.
-- Mix distributions: avg psychiatry_pct, counselor_pct, social_worker_pct, mft_pct,
--                    psychologist_pct, aprn_pct — explain WHY payment_per_claim differs.
--
-- Geo levels: national ('US'), state, zip. Minimum n = 3.

with base as (
    select
        org_entity_id,
        period_year,
        org_type,
        market_tier,
        size_band,
        org_state,
        org_zip5,
        panel_per_clinician,
        servicing_npi_count,
        claims_per_beneficiary,
        payment_per_claim,
        psychiatry_pct,
        counselor_pct,
        social_worker_pct,
        mft_pct,
        psychologist_pct,
        aprn_pct
    from {{ ref('org_kpis') }}
    where org_type              != 'OTHER'
      and panel_per_clinician    is not null
      and panel_per_clinician    >  0
      and claims_per_beneficiary is not null
      and payment_per_claim      is not null
),

-- ── type_only — widest cut, org_type match only ───────────────────────────────

to_national as (
    select org_type, 'type_only' as peer_group,
        cast(null as string) as size_band, cast(null as string) as market_tier,
        'national' as geo_level, 'US' as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
),

to_state as (
    select org_type, 'type_only' as peer_group,
        cast(null as string) as size_band, cast(null as string) as market_tier,
        'state' as geo_level, org_state as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base where org_state != ''
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
),

to_zip as (
    select org_type, 'type_only' as peer_group,
        cast(null as string) as size_band, cast(null as string) as market_tier,
        'zip' as geo_level, org_zip5 as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base where org_zip5 != ''
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
),

-- ── type_size — org_type + size_band ─────────────────────────────────────────

ts_national as (
    select org_type, 'type_size' as peer_group,
        size_band, cast(null as string) as market_tier,
        'national' as geo_level, 'US' as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
),

ts_state as (
    select org_type, 'type_size' as peer_group,
        size_band, cast(null as string) as market_tier,
        'state' as geo_level, org_state as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base where org_state != ''
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
),

ts_zip as (
    select org_type, 'type_size' as peer_group,
        size_band, cast(null as string) as market_tier,
        'zip' as geo_level, org_zip5 as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base where org_zip5 != ''
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
),

-- ── type_market — org_type + market_tier ─────────────────────────────────────

tm_national as (
    select org_type, 'type_market' as peer_group,
        cast(null as string) as size_band, market_tier,
        'national' as geo_level, 'US' as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
),

tm_state as (
    select org_type, 'type_market' as peer_group,
        cast(null as string) as size_band, market_tier,
        'state' as geo_level, org_state as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base where org_state != ''
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
),

tm_zip as (
    select org_type, 'type_market' as peer_group,
        cast(null as string) as size_band, market_tier,
        'zip' as geo_level, org_zip5 as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base where org_zip5 != ''
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
),

-- ── type_size_market — tightest cut ──────────────────────────────────────────

tsm_national as (
    select org_type, 'type_size_market' as peer_group,
        size_band, market_tier,
        'national' as geo_level, 'US' as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
),

tsm_state as (
    select org_type, 'type_size_market' as peer_group,
        size_band, market_tier,
        'state' as geo_level, org_state as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base where org_state != ''
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
),

tsm_zip as (
    select org_type, 'type_size_market' as peer_group,
        size_band, market_tier,
        'zip' as geo_level, org_zip5 as geo_id, period_year,
        count(distinct org_entity_id)                              as n,
        avg(panel_per_clinician)                                   as mean_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(1)]       as p25_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(2)]       as p50_panel_per_clin,
        approx_quantiles(panel_per_clinician, 4)[offset(3)]       as p75_panel_per_clin,
        stddev(panel_per_clinician)                                as std_panel_per_clin,
        avg(cast(servicing_npi_count as float64))                  as mean_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(1)]       as p25_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(2)]       as p50_clinician_count,
        approx_quantiles(servicing_npi_count, 4)[offset(3)]       as p75_clinician_count,
        avg(claims_per_beneficiary)                                as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)]    as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)]    as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)]    as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                             as std_claims_per_bene,
        avg(payment_per_claim)                                     as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)]         as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)]         as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)]         as p75_payment_per_claim,
        stddev(payment_per_claim)                                  as std_payment_per_claim,
        avg(psychiatry_pct)    as avg_psychiatry_pct,
        avg(counselor_pct)     as avg_counselor_pct,
        avg(social_worker_pct) as avg_social_worker_pct,
        avg(mft_pct)           as avg_mft_pct,
        avg(psychologist_pct)  as avg_psychologist_pct,
        avg(aprn_pct)          as avg_aprn_pct
    from base where org_zip5 != ''
    group by org_type, peer_group, size_band, market_tier, geo_level, geo_id, period_year
    having count(distinct org_entity_id) >= 3
)

select * from to_national union all
select * from to_state    union all
select * from to_zip      union all
select * from ts_national union all
select * from ts_state    union all
select * from ts_zip      union all
select * from tm_national union all
select * from tm_state    union all
select * from tm_zip      union all
select * from tsm_national union all
select * from tsm_state    union all
select * from tsm_zip
