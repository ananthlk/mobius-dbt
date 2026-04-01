{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- NPI-level KPIs per period_month. One row per servicing_npi × period_month.
-- Enriched with primary taxonomy code, state, and ZIP from NPPES.
-- Basis for individual provider peer comparison and HCPCS trend analysis.
--
-- Source truth:
--   claims  → landing_medicaid_npi.stg_doge (view over medicaid-provider-spending)
--   geo/tax → bigquery-public-data.nppes.npi_optimized (public, no load needed)
--
-- Design notes:
--   - Uses stg_doge (clean column names, confirmed accessible).
--   - NPI cast to STRING in both sources to guarantee join.
--   - ZIP trimmed to 5 digits (NPPES stores ZIP+4).
--   - primary_taxonomy_code = healthcare_provider_taxonomy_code_1 (first on NPPES record).
--   - Rows with zero beneficiaries excluded (SAFE_DIVIDE gives NULL/0 for all KPIs).
--   - Left join on NPPES: NPI not in NPPES gets empty taxonomy/state/zip — still included
--     so org-level roll-ups are complete; excluded from peer_distributions downstream.

with doge as (
    select
        cast(servicing_npi  as string)  as servicing_npi,
        cast(billing_npi    as string)  as billing_npi,
        cast(hcpcs_code     as string)  as hcpcs_code,
        period_month,
        cast(beneficiary_count as int64)   as beneficiary_count,
        cast(claim_count       as int64)   as claim_count,
        cast(total_paid        as float64) as total_paid
    from {{ source('landing_medicaid_npi', 'stg_doge') }}
    where servicing_npi is not null
      and beneficiary_count > 0
      and claim_count        > 0
),

-- Aggregate claims per NPI × month (a single NPI can appear across many HCPCS rows)
npi_month as (
    select
        servicing_npi,
        period_month,
        sum(beneficiary_count)  as panel_size,
        sum(claim_count)        as total_claims,
        sum(total_paid)         as total_paid
    from doge
    group by 1, 2
),

-- NPPES: one row per NPI, primary taxonomy + practice location
nppes as (
    select
        cast(npi as string) as npi,
        coalesce(
            nullif(trim(cast(healthcare_provider_taxonomy_code_1 as string)), ''),
            ''
        )                                                                           as primary_taxonomy_code,
        coalesce(
            nullif(trim(cast(
                provider_business_practice_location_address_state_name as string
            )), ''),
            ''
        )                                                                           as provider_state,
        -- ZIP+4 → 5-digit ZIP
        substr(
            coalesce(
                nullif(trim(cast(
                    provider_business_practice_location_address_postal_code as string
                )), ''),
                ''
            ),
            1, 5
        )                                                                           as provider_zip5
    from {{ source('nppes_public', 'npi_optimized') }}
    where npi is not null
)

select
    m.servicing_npi,
    m.period_month,
    coalesce(n.primary_taxonomy_code, '')   as primary_taxonomy_code,
    coalesce(n.provider_state,         '')  as provider_state,
    coalesce(n.provider_zip5,          '')  as provider_zip5,
    m.panel_size,
    m.total_claims,
    m.total_paid,
    safe_divide(m.total_claims, m.panel_size)   as claims_per_beneficiary,
    safe_divide(m.total_paid,   m.total_claims) as payment_per_claim
from npi_month m
left join nppes n on n.npi = m.servicing_npi
