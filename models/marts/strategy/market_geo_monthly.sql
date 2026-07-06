{{
  config(
    materialized='table',
  )
}}

-- Market Geo Monthly
-- Grain: one row per zip5 × period_month.
-- Classifies each FL ZIP as urban/suburban/rural/ultra_rural via RUCA.
-- Computes supply (provider count) and demand (beneficiary count) to flag
-- shortage vs surplus markets.

with bh_codes as (
    select hcpcs_code from {{ ref('stg_bh_codes') }}
),

fl_npis as (
    select distinct
        cast(npi as string) as npi,
        left(trim(cast(provider_business_mailing_address_postal_code as string)), 5) as zip5
    from {{ source('nppes_public', 'npi_raw') }}
    where npi is not null
      and provider_business_practice_location_address_state_name = 'FL'
      and provider_business_mailing_address_postal_code is not null
),

-- NPI × month with ZIP, filtered to BH codes
npi_zip_month as (
    select
        cast(d.servicing_npi as string) as servicing_npi,
        fl.zip5,
        d.period_month,
        sum(cast(d.beneficiary_count as int64))  as beneficiary_count,
        sum(cast(d.claim_count       as int64))  as claim_count,
        sum(cast(d.total_paid        as float64)) as total_paid
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    inner join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
    inner join fl_npis fl on fl.npi = cast(d.servicing_npi as string)
    where d.servicing_npi is not null
      and d.period_month is not null
    group by 1, 2, 3
),

-- Aggregate to ZIP × month
zip_month as (
    select
        zip5,
        period_month,
        count(distinct servicing_npi) as provider_count,
        sum(beneficiary_count)        as total_beneficiaries,
        sum(claim_count)              as total_claims,
        sum(total_paid)               as total_paid
    from npi_zip_month
    group by 1, 2
)

select
    zm.zip5,
    coalesce(r.po_name, 'Unknown')       as po_name,
    coalesce(r.ruca_category, 'unknown')  as ruca_category,
    coalesce(r.primary_ruca, 'unknown')   as primary_ruca,
    zm.period_month,
    left(zm.period_month, 4)              as period_year,
    zm.provider_count,
    zm.total_beneficiaries,
    zm.total_claims,
    zm.total_paid,
    -- Demand/supply ratio: beneficiaries per provider
    safe_divide(zm.total_beneficiaries, zm.provider_count) as benes_per_provider,
    -- Market archetype flags
    case
        when zm.provider_count <= 2
            then 'desert'
        when safe_divide(zm.total_beneficiaries, zm.provider_count) > 500
            then 'shortage'
        when safe_divide(zm.total_beneficiaries, zm.provider_count) < 50
            then 'surplus'
        else 'balanced'
    end as supply_demand_flag
from zip_month zm
left join {{ ref('ruca_fl_zips') }} r on r.zip5 = zm.zip5
