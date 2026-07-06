{{
  config(
    materialized='table',
  )
}}

-- FL BH Market Monthly
-- Grain: one row per hcpcs_code × period_month.
-- Scope: FL servicing NPIs only (via NPPES state filter).
-- Source: stg_doge (national Medicaid) filtered to 81 BH codes.

with bh_codes as (
    select hcpcs_code, ahca_category, care_stage, primary_metric
    from {{ ref('stg_bh_codes') }}
),

fl_servicing_npis as (
    select distinct cast(npi as string) as npi
    from {{ source('nppes_public', 'npi_raw') }}
    where npi is not null
      and provider_business_practice_location_address_state_name = 'FL'
),

doge_fl as (
    select
        d.hcpcs_code,
        d.period_month,
        cast(d.beneficiary_count as int64)   as beneficiary_count,
        cast(d.claim_count       as int64)   as claim_count,
        cast(d.total_paid        as float64) as total_paid
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    inner join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
    inner join fl_servicing_npis fl on fl.npi = cast(d.servicing_npi as string)
    where d.servicing_npi is not null
      and d.period_month   is not null
)

select
    d.hcpcs_code,
    bh.ahca_category,
    bh.care_stage,
    bh.primary_metric,
    d.period_month,
    left(d.period_month, 4) as period_year,
    sum(d.beneficiary_count) as total_beneficiaries,
    sum(d.claim_count)       as total_claims,
    sum(d.total_paid)        as total_paid,
    -- Market average rates at code × month grain
    safe_divide(sum(d.total_paid), sum(d.beneficiary_count)) as rate_per_beneficiary,
    safe_divide(sum(d.total_paid), sum(d.claim_count))       as rate_per_claim
from doge_fl d
join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
group by 1, 2, 3, 4, 5, 6
