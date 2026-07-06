{{
  config(
    materialized='table',
  )
}}

-- Org Market Profile
-- Grain: one row per org_slug × period_month.
-- Summarizes each org's geographic footprint from org_geo_monthly:
--   how many ZIPs, urban/rural mix, desert/shortage exposure, market concentration.

select
    org_slug,
    is_solo_practitioner,
    period_month,
    left(period_month, 4) as period_year,

    -- Footprint size
    count(distinct zip5)        as zip_count,
    sum(provider_count)         as total_providers_across_zips,
    sum(total_beneficiaries)    as total_beneficiaries,
    sum(total_claims)           as total_claims,
    sum(total_paid)             as total_paid,

    -- RUCA mix (% of org revenue by category)
    safe_divide(
        sum(case when ruca_category = 'urban' then total_paid end),
        sum(total_paid)
    ) as pct_revenue_urban,
    safe_divide(
        sum(case when ruca_category = 'suburban' then total_paid end),
        sum(total_paid)
    ) as pct_revenue_suburban,
    safe_divide(
        sum(case when ruca_category in ('rural', 'ultra_rural') then total_paid end),
        sum(total_paid)
    ) as pct_revenue_rural,

    -- Supply/demand exposure (% of org revenue by market flag)
    safe_divide(
        sum(case when market_supply_demand_flag = 'desert' then total_paid end),
        sum(total_paid)
    ) as pct_revenue_desert,
    safe_divide(
        sum(case when market_supply_demand_flag = 'shortage' then total_paid end),
        sum(total_paid)
    ) as pct_revenue_shortage,
    safe_divide(
        sum(case when market_supply_demand_flag = 'balanced' then total_paid end),
        sum(total_paid)
    ) as pct_revenue_balanced,
    safe_divide(
        sum(case when market_supply_demand_flag = 'surplus' then total_paid end),
        sum(total_paid)
    ) as pct_revenue_surplus,

    -- ZIP counts by type
    countif(ruca_category = 'urban')                    as urban_zip_count,
    countif(ruca_category in ('rural', 'ultra_rural'))  as rural_zip_count,
    countif(market_supply_demand_flag = 'desert')       as desert_zip_count,
    countif(market_supply_demand_flag = 'shortage')     as shortage_zip_count,

    -- Market concentration: weighted avg share across ZIPs
    -- High = dominant in their markets, Low = small player everywhere
    safe_divide(
        sum(zip_paid_share * total_paid),
        sum(total_paid)
    ) as weighted_avg_market_share,

    -- Dominant market type
    case
        when safe_divide(
            sum(case when ruca_category = 'urban' then total_paid end),
            sum(total_paid)
        ) >= 0.8 then 'urban'
        when safe_divide(
            sum(case when ruca_category in ('rural', 'ultra_rural') then total_paid end),
            sum(total_paid)
        ) >= 0.5 then 'rural'
        else 'mixed'
    end as market_type,

    -- Operating model classification
    case
        when count(distinct zip5) = 1 then 'single_market'
        when count(distinct zip5) <= 3 then 'local'
        when count(distinct zip5) <= 10 then 'regional'
        else 'multi_market'
    end as operating_footprint

from {{ ref('org_geo_monthly') }}
group by 1, 2, 3, 4
