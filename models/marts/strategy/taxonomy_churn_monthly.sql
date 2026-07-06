{{
  config(
    materialized='table',
  )
}}

-- Taxonomy Churn Monthly
-- Grain: one row per taxonomy_code × period_month.
-- Classifies each active NPI as retained, new_entrant, or returning.
-- Separately counts churned NPIs (not in current or prior 3 months).
-- 3-month lookback window accounts for PTO, data lags, etc.

with bh_tax as (
    select taxonomy_code
    from {{ ref('stg_bh_taxonomies') }}
),

-- NPI-level: every month an NPI billed a BH code, with their taxonomy
npi_months as (
    select distinct
        cast(d.servicing_npi as string) as servicing_npi,
        fl.healthcare_provider_taxonomy_code_1 as taxonomy_code,
        d.period_month
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    inner join {{ ref('stg_bh_codes') }} bh on bh.hcpcs_code = d.hcpcs_code
    inner join {{ source('nppes_public', 'npi_raw') }} fl
        on cast(fl.npi as string) = cast(d.servicing_npi as string)
        and fl.provider_business_practice_location_address_state_name = 'FL'
    inner join bh_tax bt on bt.taxonomy_code = cast(fl.healthcare_provider_taxonomy_code_1 as string)
    where d.servicing_npi is not null
      and d.period_month is not null
),

-- All distinct months in the dataset
all_months as (
    select distinct period_month from npi_months
),

-- For each NPI × taxonomy, their first-ever billing month
first_appearance as (
    select
        servicing_npi,
        taxonomy_code,
        min(period_month) as first_month
    from npi_months
    group by 1, 2
),

-- For each NPI × taxonomy × month: was this NPI active?
-- Also check: were they active in any of the prior 3 months?
-- Were they ever active before the prior 3 month window?
classified as (
    select
        am.period_month,
        nm.servicing_npi,
        nm.taxonomy_code,
        -- Active this month
        1 as is_active,
        -- Retained: also billed in at least one of prior 3 months
        case when exists (
            select 1 from npi_months p
            where p.servicing_npi = nm.servicing_npi
              and p.taxonomy_code = nm.taxonomy_code
              and p.period_month < am.period_month
              and p.period_month >= format_date('%Y-%m', date_sub(parse_date('%Y-%m', am.period_month), interval 3 month))
        ) then 1 else 0 end as is_retained,
        -- New entrant: first ever month
        case when fa.first_month = am.period_month then 1 else 0 end as is_new_entrant
    from all_months am
    inner join npi_months nm on nm.period_month = am.period_month
    inner join first_appearance fa
        on fa.servicing_npi = nm.servicing_npi
        and fa.taxonomy_code = nm.taxonomy_code
),

-- Active NPIs with classification
active_classified as (
    select
        period_month,
        taxonomy_code,
        servicing_npi,
        is_retained,
        is_new_entrant,
        -- Returning: not retained, not new, but active (was here before, took a break >3mo)
        case when is_retained = 0 and is_new_entrant = 0 then 1 else 0 end as is_returning
    from classified
),

-- Churned: billed in the 3-month window ending 3 months before current month,
-- but NOT in any of the 3 months prior to current month, and NOT in current month.
-- e.g. for 2024-04: billed in {2023-10..2023-12}, not in {2024-01..2024-04}
churned as (
    select
        am.period_month,
        nm.taxonomy_code,
        nm.servicing_npi
    from all_months am
    cross join (select distinct servicing_npi, taxonomy_code from npi_months) nm
    where
        -- Billed in the 3-month window ending 3 months ago
        exists (
            select 1 from npi_months p
            where p.servicing_npi = nm.servicing_npi
              and p.taxonomy_code = nm.taxonomy_code
              and p.period_month >= format_date('%Y-%m', date_sub(parse_date('%Y-%m', am.period_month), interval 6 month))
              and p.period_month < format_date('%Y-%m', date_sub(parse_date('%Y-%m', am.period_month), interval 3 month))
        )
        -- NOT in any of prior 3 months or current month
        and not exists (
            select 1 from npi_months p
            where p.servicing_npi = nm.servicing_npi
              and p.taxonomy_code = nm.taxonomy_code
              and p.period_month >= format_date('%Y-%m', date_sub(parse_date('%Y-%m', am.period_month), interval 3 month))
              and p.period_month <= am.period_month
        )
),

active_agg as (
    select
        period_month,
        taxonomy_code,
        count(distinct servicing_npi) as active_providers,
        sum(is_retained) as retained_providers,
        sum(is_new_entrant) as new_entrant_providers,
        sum(is_returning) as returning_providers
    from active_classified
    group by 1, 2
),

churned_agg as (
    select
        period_month,
        taxonomy_code,
        count(distinct servicing_npi) as churned_providers
    from churned
    group by 1, 2
)

select
    a.taxonomy_code,
    t.nucc_display_name,
    a.period_month,
    left(a.period_month, 4) as period_year,
    a.active_providers,
    a.retained_providers,
    a.new_entrant_providers,
    a.returning_providers,
    coalesce(c.churned_providers, 0) as churned_providers,
    -- Net change: new + returning - churned
    a.new_entrant_providers + a.returning_providers - coalesce(c.churned_providers, 0) as net_provider_change,
    -- Rates
    safe_divide(a.retained_providers, a.active_providers) as retention_rate,
    safe_divide(coalesce(c.churned_providers, 0), a.active_providers + coalesce(c.churned_providers, 0)) as churn_rate
from active_agg a
join {{ ref('stg_bh_taxonomies') }} t on t.taxonomy_code = a.taxonomy_code
left join churned_agg c on c.taxonomy_code = a.taxonomy_code and c.period_month = a.period_month
