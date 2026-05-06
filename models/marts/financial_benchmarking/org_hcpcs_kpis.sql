{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Organization × HCPCS code KPIs for BH codes.
-- One row per org_entity × hcpcs_code × period_year.
--
-- This is the foundation table for the three-index system:
--   payment_per_claim        → Rate Index numerator
--   claims_per_beneficiary   → Retention Index numerator
--   beneficiaries_per_clinician → Panel Load Index numerator
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
    from {{ ref('fl_bh_code_reference_enriched') }}
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

-- Join to org context
billing_org_context as (
    select
        bp.billing_npi,
        bp.entity_type_code,
        bp.primary_taxonomy_code as billing_taxonomy,
        oe.org_entity_id,
        oe.org_name,
        oe.norm_org_name,
        oe.org_type,
        oe.market_tier,
        oe.org_state,
        oe.org_zip5,
        oe.org_city
    from {{ ref('billing_npi_profiles') }} bp
    inner join {{ ref('org_entities') }} oe
        on  bp.norm_org_name = oe.norm_org_name
        and bp.org_state     = oe.org_state
        and bp.org_zip5      = oe.org_zip5
    where bp.norm_org_name != ''
),

-- Aggregate to org × code × year
org_code_agg as (
    select
        ctx.org_entity_id,
        ctx.org_name,
        ctx.norm_org_name,
        ctx.org_type,
        ctx.market_tier,
        ctx.org_state,
        ctx.org_zip5,
        ctx.org_city,
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
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
    having sum(d.claim_count) > 0
)

select
    org_entity_id,
    org_name,
    norm_org_name,
    org_type,
    market_tier,
    org_state,
    org_zip5,
    org_city,
    hcpcs_code,
    category,
    service_line,
    period_year,
    servicing_npi_count,
    total_claims,
    round(total_paid, 2)                                                    as total_paid,
    total_beneficiaries,

    -- The three KPI numerators
    round(safe_divide(total_paid, total_claims), 2)                        as payment_per_claim,
    round(safe_divide(total_claims, total_beneficiaries), 4)               as claims_per_beneficiary,
    round(safe_divide(total_beneficiaries, servicing_npi_count), 2)        as beneficiaries_per_clinician

from org_code_agg
