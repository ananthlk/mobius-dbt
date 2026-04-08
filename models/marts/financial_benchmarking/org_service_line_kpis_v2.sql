{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
    tags=['periodic'],
    enabled=var('run_periodic', false),
  )
}}

-- Organization-level KPIs by service line using credentialing-deduped org identity (org_npi_map).
-- Replaces org_service_line_kpis which uses site-level dedup (org_entities + billing_npi_profiles).
-- Grain: one row per org_slug x service_line x period_year.
--
-- Service line classification driven by fl_bh_code_reference (AHCA categories).
-- Non-BH codes get service_line = 'other'.
--
-- WHY service lines matter for benchmarking:
--   Org-level panel_per_clinician conflates fundamentally different billing models:
--     - ACT (H0040): one NPI bills for an entire ACT team (~8-12 staff), inflating panel/clin
--     - Case management (T1017): one person "manages" hundreds of beneficiaries -- not therapy
--     - Residential (H0019): per-diem billing, individual clinician NPIs rarely appear
--   Separating by service line allows meaningful peer comparison:
--     e.g., CMHC outpatient therapy arm vs. peers' outpatient therapy arm.

with bh_codes as (
    select hcpcs_code, ahca_category
    from {{ source('financial_reference', 'fl_bh_code_reference') }}
),

org_billing_map as (
    select distinct
        om.org_slug,
        om.org_name,
        om.org_type,
        om.org_primary_state  as org_state,
        om.org_primary_zip5   as org_zip5,
        om.org_primary_city   as org_city,
        om.billing_npi
    from {{ ref('org_npi_map') }} om
    where om.in_doge = true
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
    where d.billing_npi   is not null
      and d.servicing_npi is not null
      and d.period_month  is not null
      and d.hcpcs_code    is not null
),

org_service_claims as (
    select
        m.org_slug,
        m.org_name,
        m.org_state,
        m.org_zip5,
        m.org_city,
        m.org_type,
        d.period_year,
        d.service_line,
        d.servicing_npi,
        sum(d.beneficiary_count) as bene_count,
        sum(d.claim_count)       as claim_count,
        sum(d.total_paid)        as total_paid
    from org_billing_map m
    join doge_with_service_line d on d.billing_npi = m.billing_npi
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9
),

org_service_annual as (
    select
        org_slug,
        org_name,
        org_state,
        org_zip5,
        org_city,
        org_type,
        period_year,
        service_line,
        count(distinct servicing_npi) as servicing_npi_count,
        sum(bene_count)               as panel_size,
        sum(claim_count)              as total_claims,
        sum(total_paid)               as total_paid
    from org_service_claims
    group by 1, 2, 3, 4, 5, 6, 7, 8
)

select
    a.org_slug,
    a.org_name,
    a.org_state,
    a.org_zip5,
    a.org_city,
    a.org_type,
    k.market_tier,
    a.period_year,
    a.service_line,
    a.servicing_npi_count,
    a.panel_size,
    a.total_claims,
    round(a.total_paid, 2)                                            as total_paid,
    round(safe_divide(a.panel_size, a.servicing_npi_count), 2)       as panel_per_clinician,
    k.size_band,
    round(safe_divide(a.total_claims, a.panel_size), 4)              as claims_per_beneficiary,
    round(safe_divide(a.total_paid,   a.total_claims), 2)            as payment_per_claim

from org_service_annual a
left join {{ ref('org_kpis_v2') }} k
    on  k.org_slug    = a.org_slug
    and k.period_year = a.period_year
where a.panel_size   > 0
  and a.total_claims  > 0
