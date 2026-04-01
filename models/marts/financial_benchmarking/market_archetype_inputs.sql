{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Market archetype scoring inputs: provider density + KPI aggregates per geo × taxonomy × period.
-- The API reads this to score markets against the 4-dimension archetype framework
-- (provider availability, demand pressure, utilization, payment environment).
-- Scoring logic lives in the API — this model only pre-aggregates the raw inputs.
--
-- Geo levels: 'state', 'zip'  (national is the reference frame, not a market unit)
--
-- Columns:
--   provider_count          — distinct servicing NPIs in this geo/taxonomy/period
--   total_beneficiaries     — sum of panel sizes (proxy for total demand in the market)
--   avg_panel_size          — mean panel size across providers (demand pressure signal)
--   avg_claims_per_bene     — mean utilization across providers
--   avg_payment_per_claim   — mean effective payment rate
--   p25/p75 variants        — distribution spread for the archetype dimension scoring

with base as (
    select
        servicing_npi,
        period_month,
        primary_taxonomy_code,
        provider_state,
        provider_zip5,
        panel_size,
        claims_per_beneficiary,
        payment_per_claim,
        total_claims,
        total_paid
    from {{ ref('npi_kpis_monthly') }}
    where primary_taxonomy_code != ''
      and panel_size              > 0
      and claims_per_beneficiary  is not null
      and payment_per_claim       is not null
),

-- ── State ─────────────────────────────────────────────────────────────────────
state_level as (
    select
        'state'                                             as geo_level,
        provider_state                                      as geo_id,
        primary_taxonomy_code,
        period_month,
        count(distinct servicing_npi)                       as provider_count,
        sum(panel_size)                                     as total_beneficiaries,
        safe_divide(sum(panel_size), count(distinct servicing_npi)) as avg_panel_size,
        -- Aggregate-level utilization: total claims / total unique beneficiaries
        safe_divide(sum(total_claims), sum(panel_size))     as avg_claims_per_bene,
        -- Aggregate-level payment: total paid / total claims
        safe_divide(sum(total_paid),   sum(total_claims))   as avg_payment_per_claim,
        -- Distribution spread for dimension scoring (API maps these to 0–3 scores)
        approx_quantiles(panel_size,           4)[offset(1)] as p25_panel_size,
        approx_quantiles(panel_size,           4)[offset(3)] as p75_panel_size,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)] as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)] as p75_claims_per_bene,
        approx_quantiles(payment_per_claim,    4)[offset(1)] as p25_payment_per_claim,
        approx_quantiles(payment_per_claim,    4)[offset(3)] as p75_payment_per_claim
    from base
    where provider_state != ''
    group by 1, 2, 3, 4
    having count(distinct servicing_npi) >= 3
),

-- ── ZIP ───────────────────────────────────────────────────────────────────────
zip_level as (
    select
        'zip'                                               as geo_level,
        provider_zip5                                       as geo_id,
        primary_taxonomy_code,
        period_month,
        count(distinct servicing_npi)                       as provider_count,
        sum(panel_size)                                     as total_beneficiaries,
        safe_divide(sum(panel_size), count(distinct servicing_npi)) as avg_panel_size,
        safe_divide(sum(total_claims), sum(panel_size))     as avg_claims_per_bene,
        safe_divide(sum(total_paid),   sum(total_claims))   as avg_payment_per_claim,
        approx_quantiles(panel_size,           4)[offset(1)] as p25_panel_size,
        approx_quantiles(panel_size,           4)[offset(3)] as p75_panel_size,
        approx_quantiles(claims_per_beneficiary, 4)[offset(1)] as p25_claims_per_bene,
        approx_quantiles(claims_per_beneficiary, 4)[offset(3)] as p75_claims_per_bene,
        approx_quantiles(payment_per_claim,    4)[offset(1)] as p25_payment_per_claim,
        approx_quantiles(payment_per_claim,    4)[offset(3)] as p75_payment_per_claim
    from base
    where provider_zip5 != ''
    group by 1, 2, 3, 4
    having count(distinct servicing_npi) >= 3
)

select * from state_level
union all
select * from zip_level
