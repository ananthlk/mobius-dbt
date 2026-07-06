{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
    tags=['periodic'],
    enabled=var('run_periodic', false),
  )
}}

-- Monthly care-stage KPI trends (2019–2024) for FL Medicaid.
-- Same methodology as `care_stage_rate_benchmarks` but at period_month grain.
-- P50 only (no P25/P75) to keep table manageable.
--
-- Grain: care_stage × period_month × peer_group × dimension_value
--
-- Peer groups: all_fl, by_entity, by_org_type, by_size, by_market,
--              by_taxonomy, rest_of_fl_excl
-- KPIs:        payment_per_claim, revenue_per_beneficiary,
--              claims_per_beneficiary, beneficiaries_per_clinician
--
-- Minimum 3 orgs per cell.
-- Note: org_type/size_band/market_tier are a 2024 point-in-time snapshot
-- applied to all historical months (same as hcpcs_rate_trends).

with bh_codes as (
    select
        hcpcs_code,
        ahca_category,
        care_stage
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
      and CLAIM_FROM_MONTH          >= '2019-01'
),

doge_fl_bh as (
    select
        d.*,
        bh.care_stage
    from doge_fl d
    inner join nppes_fl_professional n on n.npi = d.servicing_npi
    inner join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
),

billing_org_context as (
    select
        bp.billing_npi,
        bp.entity_type_code,
        bp.primary_taxonomy_code as billing_taxonomy,
        oe.org_entity_id,
        oe.org_type,
        oe.market_tier,
        ok.size_band
    from {{ ref('billing_npi_profiles') }} bp
    inner join {{ ref('org_entities') }} oe
        on  bp.norm_org_name = oe.norm_org_name
        and bp.org_state     = oe.org_state
        and bp.org_zip5      = oe.org_zip5
    left join {{ ref('org_kpis') }} ok
        on  oe.org_entity_id = ok.org_entity_id
        and ok.period_year   = '2024'
    where bp.norm_org_name != ''
),

claims_with_context as (
    select
        d.servicing_npi,
        d.billing_npi,
        d.care_stage,
        d.period_month,
        d.claim_count,
        d.total_paid,
        d.beneficiary_count,
        ctx.org_entity_id,
        case ctx.entity_type_code
            when '1' then 'individual'
            when '2' then 'organization'
            else 'unknown'
        end as billing_entity,
        ctx.billing_taxonomy,
        ctx.org_type,
        ctx.size_band,
        ctx.market_tier
    from doge_fl_bh d
    left join billing_org_context ctx on ctx.billing_npi = d.billing_npi
),

-- Org × care_stage × period_month rollup
org_stage_monthly as (
    select
        care_stage,
        period_month,
        org_entity_id,
        billing_entity,
        billing_taxonomy,
        org_type,
        size_band,
        market_tier,
        count(distinct servicing_npi)                                      as svc_npi_count,
        sum(claim_count)                                                   as org_claims,
        sum(total_paid)                                                    as org_paid,
        sum(beneficiary_count)                                             as org_beneficiaries,
        safe_divide(sum(total_paid),   sum(claim_count))                   as payment_per_claim,
        safe_divide(sum(total_paid),   sum(beneficiary_count))             as revenue_per_beneficiary,
        safe_divide(sum(claim_count),  sum(beneficiary_count))             as claims_per_beneficiary,
        safe_divide(sum(beneficiary_count), count(distinct servicing_npi)) as beneficiaries_per_clinician
    from claims_with_context
    where org_entity_id is not null
      and care_stage    is not null
    group by 1, 2, 3, 4, 5, 6, 7, 8
    having sum(claim_count) > 0
),

-- ── all_fl ────────────────────────────────────────────────────────
all_fl as (
    select care_stage, period_month,
        'all_fl' as peer_group, cast(null as string) as dimension_value,
        count(*) as org_count, sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician
    from org_stage_monthly
    group by 1, 2
    having count(*) >= 3
),

-- ── by_entity ─────────────────────────────────────────────────────
by_entity as (
    select care_stage, period_month,
        'by_entity' as peer_group, billing_entity as dimension_value,
        count(*) as org_count, sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician
    from org_stage_monthly
    where billing_entity is not null and billing_entity != 'unknown'
    group by 1, 2, 4
    having count(*) >= 3
),

-- ── by_org_type ───────────────────────────────────────────────────
by_org_type as (
    select care_stage, period_month,
        'by_org_type' as peer_group, org_type as dimension_value,
        count(*) as org_count, sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician
    from org_stage_monthly
    where org_type is not null
    group by 1, 2, 4
    having count(*) >= 3
),

-- ── by_size ───────────────────────────────────────────────────────
by_size as (
    select care_stage, period_month,
        'by_size' as peer_group, size_band as dimension_value,
        count(*) as org_count, sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician
    from org_stage_monthly
    where size_band is not null
    group by 1, 2, 4
    having count(*) >= 3
),

-- ── by_market ─────────────────────────────────────────────────────
by_market as (
    select care_stage, period_month,
        'by_market' as peer_group, market_tier as dimension_value,
        count(*) as org_count, sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician
    from org_stage_monthly
    where market_tier is not null
    group by 1, 2, 4
    having count(*) >= 3
),

-- ── by_taxonomy ───────────────────────────────────────────────────
by_taxonomy as (
    select care_stage, period_month,
        'by_taxonomy' as peer_group, billing_taxonomy as dimension_value,
        count(*) as org_count, sum(svc_npi_count) as svc_npi_count,
        sum(org_claims) as total_claims, sum(org_paid) as total_paid,
        sum(org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician
    from org_stage_monthly
    where billing_taxonomy is not null and billing_taxonomy != ''
    group by 1, 2, 4
    having count(*) >= 3
),

-- ── rest_of_fl_excl: drives Backbone "CMHC vs Rest-of-FL" trend line ──
org_types_list as (
    select distinct org_type as excl_type
    from org_stage_monthly
    where org_type is not null
),

rest_of_fl_excl as (
    select a.care_stage, a.period_month,
        'rest_of_fl_excl' as peer_group,
        t.excl_type as dimension_value,
        count(*) as org_count, sum(a.svc_npi_count) as svc_npi_count,
        sum(a.org_claims) as total_claims, sum(a.org_paid) as total_paid,
        sum(a.org_beneficiaries) as total_beneficiaries,
        round(approx_quantiles(a.payment_per_claim, 100)[offset(50)], 2) as p50_payment_per_claim,
        round(approx_quantiles(a.revenue_per_beneficiary, 100)[offset(50)], 2) as p50_revenue_per_bene,
        round(approx_quantiles(a.claims_per_beneficiary, 100)[offset(50)], 2) as p50_claims_per_bene,
        round(approx_quantiles(a.beneficiaries_per_clinician, 100)[offset(50)], 2) as p50_bene_per_clinician
    from org_stage_monthly a
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
