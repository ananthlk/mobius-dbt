{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Organization-level KPIs aggregated by service line from DOGE billing NPI claims.
-- One row per org_entity × period_year × service_line.
--
-- Service line classification driven by fl_bh_code_reference (AHCA categories).
-- Non-BH codes get service_line = 'other'.
--
-- WHY service lines matter for benchmarking:
--   Org-level panel_per_clinician conflates fundamentally different billing models:
--     - ACT (H0040): one NPI bills for an entire ACT team (~8-12 staff), inflating panel/clin
--     - Case management (T1017): one person "manages" hundreds of beneficiaries — not therapy
--     - Residential (H0019): per-diem billing, individual clinician NPIs rarely appear
--   Separating by service line allows meaningful peer comparison:
--     e.g., CMHC outpatient therapy arm vs. peers' outpatient therapy arm.

with bh_codes as (
    select hcpcs_code, ahca_category
    from {{ ref('fl_bh_code_reference_enriched') }}
),

org_billing_map as (
    select
        oe.org_entity_id,
        oe.org_name,
        oe.norm_org_name,
        oe.org_state,
        oe.org_zip5,
        oe.org_city,
        oe.primary_taxonomy_code,
        oe.org_type,
        oe.market_tier,
        oe.billing_npi_count,
        bp.billing_npi
    from {{ ref('org_entities') }} oe
    join {{ ref('billing_npi_profiles') }} bp
        on  oe.norm_org_name = bp.norm_org_name
        and oe.org_state      = bp.org_state
        and oe.org_zip5       = bp.org_zip5
),

doge_with_service_line as (
    select
        cast(d.billing_npi   as string)      as billing_npi,
        cast(d.servicing_npi as string)      as servicing_npi,
        left(d.period_month, 4)              as period_year,
        cast(d.beneficiary_count as int64)   as beneficiary_count,
        cast(d.claim_count       as int64)   as claim_count,
        cast(d.total_paid        as float64) as total_paid,
        coalesce(bh.ahca_category, 'other')  as service_line
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    left join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
    where d.billing_npi  is not null
      and d.servicing_npi is not null
      and d.period_month  is not null
      and d.hcpcs_code    is not null
),

org_service_claims as (
    select
        m.org_entity_id,
        m.org_name,
        m.norm_org_name,
        m.org_state,
        m.org_zip5,
        m.org_city,
        m.primary_taxonomy_code,
        m.org_type,
        m.market_tier,
        m.billing_npi_count,
        d.period_year,
        d.service_line,
        d.servicing_npi,
        sum(d.beneficiary_count) as bene_count,
        sum(d.claim_count)       as claim_count,
        sum(d.total_paid)        as total_paid
    from org_billing_map m
    join doge_with_service_line d on d.billing_npi = m.billing_npi
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13
),

org_service_annual as (
    select
        org_entity_id,
        org_name,
        norm_org_name,
        org_state,
        org_zip5,
        org_city,
        primary_taxonomy_code,
        org_type,
        market_tier,
        billing_npi_count,
        period_year,
        service_line,
        count(distinct servicing_npi) as servicing_npi_count,
        sum(bene_count)               as panel_size,
        sum(claim_count)              as total_claims,
        sum(total_paid)               as total_paid
    from org_service_claims
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
)

select
    org_entity_id,
    org_name,
    norm_org_name,
    org_state,
    org_zip5,
    org_city,
    primary_taxonomy_code,
    org_type,
    market_tier,
    billing_npi_count,
    period_year,
    service_line,
    servicing_npi_count,
    panel_size,
    total_claims,
    round(total_paid, 2)                                              as total_paid,
    round(safe_divide(panel_size, servicing_npi_count), 2)           as panel_per_clinician,
    -- Size band derived from service-line panel_per_clinician for service-line-aware peer grouping
    case
        when safe_divide(panel_size, servicing_npi_count) <  100 then 'small'
        when safe_divide(panel_size, servicing_npi_count) <  500 then 'medium'
        else 'large'
    end                                                               as size_band,
    round(safe_divide(total_claims, panel_size), 4)                  as claims_per_beneficiary,
    round(safe_divide(total_paid,   total_claims), 2)                as payment_per_claim

from org_service_annual
where panel_size  > 0
  and total_claims > 0
