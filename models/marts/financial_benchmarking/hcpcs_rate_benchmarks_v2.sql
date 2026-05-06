{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
    tags=['periodic'],
    enabled=var('run_periodic', false),
  )
}}

-- HCPCS-level payment benchmarks (P25/P50/P75) for FL Medicaid — v2.
-- Uses credentialing-deduped org identity (org_npi_map, 1,474 orgs).
--
-- MONTHLY grain: each org × code × month is one observation.
-- This fixes two problems with annual grain:
--   1. RPB (revenue per beneficiary) — bene counts are unique per month,
--      can't be summed across months without double-counting.
--   2. More observations → tighter percentile distributions.
--
-- PARALLEL single-dimension cuts (not nested):
--   all_fl, by_entity, by_org_type, by_size, by_market, by_taxonomy, rest_of_fl_excl
--
-- Minimum 3 org-months per cell.

with bh_codes as (
    select
        hcpcs_code,
        ahca_category
    from {{ ref('fl_bh_code_reference_enriched') }}
),

nppes_fl_professional as (
    select cast(npi as string) as npi
    from {{ source('nppes_public', 'npi_optimized') }}
    where npi is not null
      and cast(entity_type_code as string) = '1'
      and upper(trim(cast(
          provider_business_practice_location_address_state_name as string
      ))) = 'FL'
),

doge_fl as (
    select
        cast(BILLING_PROVIDER_NPI_NUM  as string)  as billing_npi,
        cast(SERVICING_PROVIDER_NPI_NUM as string) as servicing_npi,
        trim(cast(HCPCS_CODE           as string)) as hcpcs_code,
        safe_cast(CLAIM_FROM_MONTH     as string)  as period_month,
        cast(TOTAL_CLAIMS              as int64)   as claim_count,
        cast(TOTAL_PAID                as float64) as total_paid,
        cast(TOTAL_UNIQUE_BENEFICIARIES as int64)  as beneficiary_count
    from {{ source('landing_medicaid_npi', 'medicaid_provider_spending') }}
    where SERVICING_PROVIDER_NPI_NUM is not null
      and HCPCS_CODE                 is not null
      and trim(cast(HCPCS_CODE as string)) != ''
      and TOTAL_CLAIMS               > 0
      and substr(safe_cast(CLAIM_FROM_MONTH as string), 1, 4) = '2024'
),

doge_fl_professional as (
    select
        d.*,
        coalesce(bh.ahca_category, 'other') as service_line
    from doge_fl d
    inner join nppes_fl_professional n on n.npi = d.servicing_npi
    left join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
),

-- v2: Use org_npi_map + org_kpis_v2 instead of org_entities + org_kpis
billing_org_context as (
    select distinct
        om.billing_npi,
        om.entity_type_code,
        om.primary_taxonomy_code as billing_taxonomy,
        om.org_slug,
        om.org_type,
        ok.market_tier,
        ok.size_band
    from {{ ref('org_npi_map') }} om
    left join {{ ref('org_kpis_v2') }} ok
        on  om.org_slug    = ok.org_slug
        and ok.period_year = '2024'
    where om.in_doge = true
),

claims_with_context as (
    select
        d.servicing_npi,
        d.billing_npi,
        d.hcpcs_code,
        d.period_month,
        d.service_line,
        d.claim_count,
        d.total_paid,
        d.beneficiary_count,
        ctx.org_slug,
        case ctx.entity_type_code
            when '1' then 'individual'
            when '2' then 'organization'
            else 'unknown'
        end as billing_entity,
        ctx.billing_taxonomy,
        ctx.org_type,
        ctx.size_band,
        ctx.market_tier
    from doge_fl_professional d
    left join billing_org_context ctx on ctx.billing_npi = d.billing_npi
),

-- Aggregate to ORG × CODE × MONTH (monthly grain)
-- PPC = paid/claims (rate per claim)
-- RPB = paid/benes  (revenue per beneficiary per month — benes are unique within month)
org_hcpcs_monthly as (
    select
        hcpcs_code,
        period_month,
        service_line,
        org_slug,
        billing_entity,
        billing_taxonomy,
        org_type,
        size_band,
        market_tier,
        count(distinct servicing_npi)                            as svc_npi_count,
        sum(claim_count)                                         as org_claims,
        sum(total_paid)                                          as org_paid,
        sum(beneficiary_count)                                   as org_beneficiaries,
        safe_divide(sum(total_paid), sum(claim_count))           as payment_per_claim,
        safe_divide(sum(total_paid), sum(beneficiary_count))     as revenue_per_beneficiary,
        safe_divide(sum(claim_count), sum(beneficiary_count))    as claims_per_beneficiary,
        safe_divide(sum(beneficiary_count), count(distinct servicing_npi)) as beneficiaries_per_clinician
    from claims_with_context
    where org_slug is not null
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9
    having sum(claim_count) > 0
),

-- ── all_fl: baseline ────────────────────────────────────────────────────────
all_fl as (
    select hcpcs_code, service_line,
        'all_fl' as peer_group, cast(null as string) as dimension_value,
        'state' as geo_level, 'FL' as geo_id, '2024' as period_year,
        count(*) as n_org_months,
        count(distinct org_slug) as org_count,
        sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(25)], 2) as p25_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(75)], 2) as p75_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(25)], 2) as p25_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(75)], 2) as p75_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(25)], 2) as p25_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(75)], 2) as p75_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(25)], 2) as p25_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(75)], 2) as p75_bene_per_clinician
    from org_hcpcs_monthly
    group by 1, 2
    having count(*) >= 3
),

-- ── by_entity: individual vs organization ───────────────────────────────────
by_entity as (
    select hcpcs_code, service_line,
        'by_entity' as peer_group, billing_entity as dimension_value,
        'state' as geo_level, 'FL' as geo_id, '2024' as period_year,
        count(*) as n_org_months,
        count(distinct org_slug) as org_count,
        sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(25)], 2) as p25_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(75)], 2) as p75_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(25)], 2) as p25_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(75)], 2) as p75_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(25)], 2) as p25_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(75)], 2) as p75_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(25)], 2) as p25_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(75)], 2) as p75_bene_per_clinician
    from org_hcpcs_monthly
    where billing_entity is not null and billing_entity != 'unknown'
    group by 1, 2, 4
    having count(*) >= 3
),

-- ── by_org_type: CMHC / FQHC / BH_SPECIALTY / etc. ────────────────────────
by_org_type as (
    select hcpcs_code, service_line,
        'by_org_type' as peer_group, org_type as dimension_value,
        'state' as geo_level, 'FL' as geo_id, '2024' as period_year,
        count(*) as n_org_months,
        count(distinct org_slug) as org_count,
        sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(25)], 2) as p25_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(75)], 2) as p75_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(25)], 2) as p25_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(75)], 2) as p75_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(25)], 2) as p25_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(75)], 2) as p75_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(25)], 2) as p25_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(75)], 2) as p75_bene_per_clinician
    from org_hcpcs_monthly
    where org_type is not null
    group by 1, 2, 4
    having count(*) >= 3
),

-- ── by_size: small / medium / large ─────────────────────────────────────────
by_size as (
    select hcpcs_code, service_line,
        'by_size' as peer_group, size_band as dimension_value,
        'state' as geo_level, 'FL' as geo_id, '2024' as period_year,
        count(*) as n_org_months,
        count(distinct org_slug) as org_count,
        sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(25)], 2) as p25_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(75)], 2) as p75_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(25)], 2) as p25_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(75)], 2) as p75_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(25)], 2) as p25_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(75)], 2) as p75_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(25)], 2) as p25_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(75)], 2) as p75_bene_per_clinician
    from org_hcpcs_monthly
    where size_band is not null
    group by 1, 2, 4
    having count(*) >= 3
),

-- ── by_market: sparse / moderate / dense ────────────────────────────────────
by_market as (
    select hcpcs_code, service_line,
        'by_market' as peer_group, market_tier as dimension_value,
        'state' as geo_level, 'FL' as geo_id, '2024' as period_year,
        count(*) as n_org_months,
        count(distinct org_slug) as org_count,
        sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(25)], 2) as p25_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(75)], 2) as p75_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(25)], 2) as p25_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(75)], 2) as p75_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(25)], 2) as p25_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(75)], 2) as p75_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(25)], 2) as p25_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(75)], 2) as p75_bene_per_clinician
    from org_hcpcs_monthly
    where market_tier is not null
    group by 1, 2, 4
    having count(*) >= 3
),

-- ── by_taxonomy: specific billing NPI taxonomy ──────────────────────────────
by_taxonomy as (
    select hcpcs_code, service_line,
        'by_taxonomy' as peer_group, billing_taxonomy as dimension_value,
        'state' as geo_level, 'FL' as geo_id, '2024' as period_year,
        count(*) as n_org_months,
        count(distinct org_slug) as org_count,
        sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(25)], 2) as p25_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(payment_per_claim, 100)[offset(75)], 2) as p75_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(25)], 2) as p25_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(75)], 2) as p75_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(25)], 2) as p25_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(75)], 2) as p75_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(25)], 2) as p25_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(75)], 2) as p75_bene_per_clinician
    from org_hcpcs_monthly
    where billing_taxonomy is not null and billing_taxonomy != ''
    group by 1, 2, 4
    having count(*) >= 3
),

-- ── rest_of_fl_excl: All FL EXCLUDING each org_type ─────────────────────────
org_types_list as (
    select distinct org_type as excl_type
    from org_hcpcs_monthly
    where org_type is not null
),

rest_of_fl_excl as (
    select a.hcpcs_code, a.service_line,
        'rest_of_fl_excl' as peer_group,
        t.excl_type as dimension_value,
        'state' as geo_level, 'FL' as geo_id, '2024' as period_year,
        count(*) as n_org_months,
        count(distinct a.org_slug) as org_count,
        sum(a.svc_npi_count) as svc_npi_count,
        sum(a.org_claims) as total_claims, sum(a.org_paid) as total_paid,
        sum(a.org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(a.payment_per_claim, 100)[offset(25)], 2) as p25_payment_per_claim,
        round(approx_quantiles(a.payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(a.payment_per_claim, 100)[offset(75)], 2) as p75_payment_per_claim,
        round(approx_quantiles(a.revenue_per_beneficiary, 100)[offset(25)], 2) as p25_revenue_per_bene,
        round(approx_quantiles(a.revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(a.revenue_per_beneficiary, 100)[offset(75)], 2) as p75_revenue_per_bene,
        round(approx_quantiles(a.claims_per_beneficiary, 100)[offset(25)], 2) as p25_claims_per_bene,
        round(approx_quantiles(a.claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(a.claims_per_beneficiary, 100)[offset(75)], 2) as p75_claims_per_bene,
        round(approx_quantiles(a.beneficiaries_per_clinician, 100)[offset(25)], 2) as p25_bene_per_clinician,
        round(approx_quantiles(a.beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician,
        round(approx_quantiles(a.beneficiaries_per_clinician, 100)[offset(75)], 2) as p75_bene_per_clinician
    from org_hcpcs_monthly a
    cross join org_types_list t
    where a.org_type is not null and a.org_type != t.excl_type
    group by 1, 2, t.excl_type
    having count(*) >= 3
)

select * from all_fl
union all
select * from by_entity
union all
select * from by_org_type
union all
select * from by_size
union all
select * from by_market
union all
select * from by_taxonomy
union all
select * from rest_of_fl_excl
