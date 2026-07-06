{{
  config(
    materialized='table',
  )
}}

-- Taxonomy Market Monthly
-- Grain: one row per taxonomy_code × period_month.
-- Scope: FL servicing NPIs billing BH codes, restricted to the 87
--        BH-active taxonomies in stg_bh_taxonomies (>$1M all-time spend).
-- Key metric: avg_revenue_per_provider = total_paid / provider_count.

with bh_tax as (
    select taxonomy_code
    from {{ ref('stg_bh_taxonomies') }}
),

fl_npis_with_taxonomy as (
    select distinct
        cast(npi as string) as npi,
        healthcare_provider_taxonomy_code_1 as taxonomy_code
    from {{ source('nppes_public', 'npi_raw') }}
    where npi is not null
      and provider_business_practice_location_address_state_name = 'FL'
      and healthcare_provider_taxonomy_code_1 is not null
),

doge_bh_fl as (
    select
        cast(d.servicing_npi as string) as servicing_npi,
        d.period_month,
        fl.taxonomy_code,
        cast(d.beneficiary_count as int64)   as beneficiary_count,
        cast(d.claim_count       as int64)   as claim_count,
        cast(d.total_paid        as float64) as total_paid
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    inner join {{ ref('stg_bh_codes') }} bh on bh.hcpcs_code = d.hcpcs_code
    inner join fl_npis_with_taxonomy fl on fl.npi = cast(d.servicing_npi as string)
    inner join bh_tax bt on bt.taxonomy_code = fl.taxonomy_code
    where d.servicing_npi is not null
      and d.period_month   is not null
)

select
    d.taxonomy_code,
    t.nucc_display_name,
    t.nucc_classification,
    t.nucc_section,
    d.period_month,
    left(d.period_month, 4) as period_year,
    count(distinct d.servicing_npi) as provider_count,
    sum(d.beneficiary_count)        as total_beneficiaries,
    sum(d.claim_count)              as total_claims,
    sum(d.total_paid)               as total_paid,
    safe_divide(sum(d.total_paid), count(distinct d.servicing_npi)) as avg_revenue_per_provider,
    safe_divide(sum(d.total_paid), sum(d.beneficiary_count))        as rate_per_beneficiary,
    safe_divide(sum(d.total_paid), sum(d.claim_count))              as rate_per_claim
from doge_bh_fl d
join {{ ref('stg_bh_taxonomies') }} t on t.taxonomy_code = d.taxonomy_code
group by 1, 2, 3, 4, 5, 6
