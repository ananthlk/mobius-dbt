{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Pre-computed peer distribution statistics for benchmark lookups.
-- One row per: taxonomy_code × geo_level × geo_id × period_month
-- KPI stats: n, mean, p25, p50 (median), p75, std for all three KPIs.
--
-- Geo levels produced: 'national' (geo_id='US'), 'state', 'zip'
--
-- The API uses this table to:
--   1. Look up the peer distribution for a given taxonomy + geography + period.
--   2. Compute percentile rank / z-score for a subject NPI or org KPI value.
--   3. Taxonomy-weight multiple distributions when the subject has a mixed taxonomy profile.
--
-- Design notes:
--   - Only rows with both taxonomy AND geo populated are included — avoids polluting
--     distribution buckets with unknown-provider entries.
--   - Only positive KPI values enter distribution calculations (NULLs from SAFE_DIVIDE
--     and zero-claim rows are excluded via the base CTE filter).
--   - APPROX_QUANTILES(x, 4) → [min, p25, p50, p75, max]; OFFSET 1/2/3 = p25/p50/p75.
--   - Min peer group size = 5 (HAVING n >= 5) to avoid exposing single-provider buckets.

with base as (
    select
        servicing_npi,
        period_month,
        primary_taxonomy_code,
        provider_state,
        provider_zip5,
        panel_size,
        claims_per_beneficiary,
        payment_per_claim
    from {{ ref('npi_kpis_monthly') }}
    -- Require taxonomy and at least one geo dimension for meaningful peer grouping
    where primary_taxonomy_code != ''
      and panel_size            >  0
      and claims_per_beneficiary is not null
      and payment_per_claim      is not null
),

-- ── National ──────────────────────────────────────────────────────────────────
national as (
    select
        primary_taxonomy_code,
        'national'                                          as geo_level,
        'US'                                               as geo_id,
        period_month,
        count(distinct servicing_npi)                      as n,

        avg(panel_size)                                    as mean_panel_size,
        approx_quantiles(panel_size, 4)[offset(1)]        as p25_panel_size,
        approx_quantiles(panel_size, 4)[offset(2)]        as p50_panel_size,
        approx_quantiles(panel_size, 4)[offset(3)]        as p75_panel_size,
        stddev(panel_size)                                 as std_panel_size,

        avg(claims_per_beneficiary)                        as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)] as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)] as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)] as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                     as std_claims_per_bene,

        avg(payment_per_claim)                             as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)] as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)] as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)] as p75_payment_per_claim,
        stddev(payment_per_claim)                          as std_payment_per_claim
    from base
    group by 1, 2, 3, 4
    having count(distinct servicing_npi) >= 5
),

-- ── State ─────────────────────────────────────────────────────────────────────
state_level as (
    select
        primary_taxonomy_code,
        'state'                                            as geo_level,
        provider_state                                     as geo_id,
        period_month,
        count(distinct servicing_npi)                      as n,

        avg(panel_size)                                    as mean_panel_size,
        approx_quantiles(panel_size, 4)[offset(1)]        as p25_panel_size,
        approx_quantiles(panel_size, 4)[offset(2)]        as p50_panel_size,
        approx_quantiles(panel_size, 4)[offset(3)]        as p75_panel_size,
        stddev(panel_size)                                 as std_panel_size,

        avg(claims_per_beneficiary)                        as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)] as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)] as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)] as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                     as std_claims_per_bene,

        avg(payment_per_claim)                             as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)] as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)] as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)] as p75_payment_per_claim,
        stddev(payment_per_claim)                          as std_payment_per_claim
    from base
    where provider_state != ''
    group by 1, 2, 3, 4
    having count(distinct servicing_npi) >= 5
),

-- ── ZIP ───────────────────────────────────────────────────────────────────────
zip_level as (
    select
        primary_taxonomy_code,
        'zip'                                              as geo_level,
        provider_zip5                                      as geo_id,
        period_month,
        count(distinct servicing_npi)                      as n,

        avg(panel_size)                                    as mean_panel_size,
        approx_quantiles(panel_size, 4)[offset(1)]        as p25_panel_size,
        approx_quantiles(panel_size, 4)[offset(2)]        as p50_panel_size,
        approx_quantiles(panel_size, 4)[offset(3)]        as p75_panel_size,
        stddev(panel_size)                                 as std_panel_size,

        avg(claims_per_beneficiary)                        as mean_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)] as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(2)] as p50_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)] as p75_claims_per_bene,
        stddev(claims_per_beneficiary)                     as std_claims_per_bene,

        avg(payment_per_claim)                             as mean_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(1)] as p25_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(2)] as p50_payment_per_claim,
        approx_quantiles(payment_per_claim, 4)[offset(3)] as p75_payment_per_claim,
        stddev(payment_per_claim)                          as std_payment_per_claim
    from base
    where provider_zip5 != ''
    group by 1, 2, 3, 4
    having count(distinct servicing_npi) >= 5
)

select * from national
union all
select * from state_level
union all
select * from zip_level
