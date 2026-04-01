{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- HCPCS code payment trend: payment_per_claim (and volume stats) per HCPCS × geo × period_month.
-- Used by the API to render trend lines comparing an org's HCPCS payment rate to geo peers.
--
-- Geo levels: 'national' (geo_id='US'), 'state'
-- (ZIP-level HCPCS trends are too sparse to be meaningful — omitted.)
--
-- Design notes:
--   - Reads raw DOGE columns directly; no dependency on npi_kpis_monthly.
--   - State derived from NPPES practice location (same join as npi_kpis_monthly).
--   - provider_count = distinct NPIs billing this HCPCS in this geo/period,
--     which signals whether a trend point is statistically meaningful.
--   - Rows where both state and HCPCS are known are included in state_level;
--     all rows go into national.

with doge as (
    select
        cast(SERVICING_PROVIDER_NPI_NUM as string)  as servicing_npi,
        cast(HCPCS_CODE                as string)   as hcpcs_code,
        CLAIM_FROM_MONTH                            as period_month,
        cast(TOTAL_CLAIMS               as int64)   as claim_count,
        cast(TOTAL_PAID                 as float64) as total_paid
    from {{ source('landing_medicaid_npi', 'medicaid_provider_spending') }}
    where SERVICING_PROVIDER_NPI_NUM is not null
      and HCPCS_CODE                 is not null
      and TOTAL_CLAIMS               >  0
),

nppes as (
    select
        cast(npi as string) as npi,
        coalesce(
            nullif(trim(cast(
                provider_business_practice_location_address_state_name as string
            )), ''),
            ''
        ) as provider_state
    from {{ source('nppes_public', 'npi_optimized') }}
    where npi is not null
),

enriched as (
    select
        d.hcpcs_code,
        d.period_month,
        coalesce(n.provider_state, '') as provider_state,
        d.servicing_npi,
        d.claim_count,
        d.total_paid
    from doge d
    left join nppes n on n.npi = d.servicing_npi
),

-- ── National ──────────────────────────────────────────────────────────────────
national as (
    select
        hcpcs_code,
        'national'                                      as geo_level,
        'US'                                            as geo_id,
        period_month,
        count(distinct servicing_npi)                   as provider_count,
        sum(claim_count)                                as total_claims,
        sum(total_paid)                                 as total_paid,
        safe_divide(sum(total_paid), sum(claim_count))  as payment_per_claim
    from enriched
    group by 1, 2, 3, 4
),

-- ── State ─────────────────────────────────────────────────────────────────────
state_level as (
    select
        hcpcs_code,
        'state'                                         as geo_level,
        provider_state                                  as geo_id,
        period_month,
        count(distinct servicing_npi)                   as provider_count,
        sum(claim_count)                                as total_claims,
        sum(total_paid)                                 as total_paid,
        safe_divide(sum(total_paid), sum(claim_count))  as payment_per_claim
    from enriched
    where provider_state != ''
    group by 1, 2, 3, 4
)

select * from national
union all
select * from state_level
