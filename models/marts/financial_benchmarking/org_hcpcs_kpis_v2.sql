{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
    tags=['periodic'],
    enabled=var('run_periodic', false),
  )
}}

-- Organization x HCPCS code KPIs using credentialing-deduped org identity (org_npi_map).
-- Replaces org_hcpcs_kpis which uses site-level dedup (org_entities).
-- Grain: one row per org_slug x hcpcs_code x period_year.
--
-- Foundation table for the three-index system:
--   payment_per_claim        -> Rate Index numerator
--   claims_per_beneficiary   -> Retention Index numerator
--   beneficiaries_per_clinician -> Panel Load Index numerator
--
-- Scoped to BH codes via fl_bh_code_reference join.
-- FL professional servicing NPIs only (entity_type_code=1 in NPPES).

with nppes_fl_professional as (
    select cast(npi as string) as npi
    from {{ source('nppes_public', 'npi_optimized') }}
    where npi is not null
      and cast(entity_type_code as string) = '1'
      and upper(trim(cast(
          provider_business_practice_location_address_state_name as string
      ))) = 'FL'
),

bh_codes as (
    select hcpcs_code, ahca_category as category, ahca_category as service_line
    from {{ source('financial_reference', 'fl_bh_code_reference') }}
),

billing_org_context as (
    select distinct
        om.org_slug,
        om.org_name,
        om.org_type,
        om.org_primary_state as org_state,
        om.org_primary_zip5  as org_zip5,
        om.org_primary_city  as org_city,
        om.billing_npi
    from {{ ref('org_npi_map') }} om
    where om.in_doge = true
),

doge_fl as (
    select
        cast(BILLING_PROVIDER_NPI_NUM  as string)  as billing_npi,
        cast(SERVICING_PROVIDER_NPI_NUM as string) as servicing_npi,
        trim(cast(HCPCS_CODE           as string)) as hcpcs_code,
        left(safe_cast(CLAIM_FROM_MONTH as string), 4) as period_year,
        cast(TOTAL_CLAIMS              as int64)   as claim_count,
        cast(TOTAL_PAID                as float64) as total_paid,
        cast(TOTAL_UNIQUE_BENEFICIARIES as int64)  as beneficiary_count
    from {{ source('landing_medicaid_npi', 'medicaid_provider_spending') }}
    where SERVICING_PROVIDER_NPI_NUM is not null
      and HCPCS_CODE is not null
      and trim(cast(HCPCS_CODE as string)) != ''
      and TOTAL_CLAIMS > 0
),

-- Filter to FL professional servicing NPIs + BH codes
doge_fl_bh as (
    select
        d.billing_npi,
        d.servicing_npi,
        d.hcpcs_code,
        d.period_year,
        d.claim_count,
        d.total_paid,
        d.beneficiary_count,
        bh.category,
        bh.service_line
    from doge_fl d
    inner join nppes_fl_professional n on n.npi = d.servicing_npi
    inner join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
),

-- Get market_tier from org_kpis_v2 (year=2024)
market_tiers as (
    select org_slug, market_tier
    from {{ ref('org_kpis_v2') }}
    where period_year = '2024'
),

-- Aggregate to org_slug x hcpcs_code x period_year
org_code_agg as (
    select
        ctx.org_slug,
        ctx.org_name,
        ctx.org_type,
        ctx.org_state,
        ctx.org_zip5,
        d.hcpcs_code,
        d.category,
        d.service_line,
        d.period_year,
        count(distinct d.servicing_npi)    as servicing_npi_count,
        sum(d.claim_count)                 as total_claims,
        sum(d.total_paid)                  as total_paid,
        sum(d.beneficiary_count)           as total_beneficiaries
    from doge_fl_bh d
    inner join billing_org_context ctx on ctx.billing_npi = d.billing_npi
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9
    having sum(d.claim_count) > 0
)

select
    a.org_slug,
    a.org_name,
    a.org_type,
    mt.market_tier,
    a.org_state,
    a.org_zip5,
    a.hcpcs_code,
    a.category,
    a.service_line,
    a.period_year,
    a.servicing_npi_count,
    a.total_claims,
    round(a.total_paid, 2)                                                       as total_paid,
    a.total_beneficiaries,

    -- The three KPI numerators
    round(safe_divide(a.total_paid, a.total_claims), 2)                         as payment_per_claim,
    round(safe_divide(a.total_claims, a.total_beneficiaries), 4)                as claims_per_beneficiary,
    round(safe_divide(a.total_beneficiaries, a.servicing_npi_count), 2)         as beneficiaries_per_clinician

from org_code_agg a
left join market_tiers mt on mt.org_slug = a.org_slug
