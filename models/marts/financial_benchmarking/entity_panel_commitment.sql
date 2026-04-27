{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Panel commitment index: how consistently do clinicians bill Medicaid
-- month-over-month, by entity type vs market average?
--
-- Grain: one row per entity_key × period_year (48 rows total).
-- Scans stg_doge once, filtered to ~2,691 FL BH billing NPIs in org_npi_map.
-- No full-table scan — billing_npi IN (...) drives the predicate.

with npi_entities as (
    select
        billing_npi,
        case
            when cmhc_tier = 'tier1_bhpf'      then 'bhpf'
            when cmhc_tier = 'tier2_fbha'       then 'fbha'
            when cmhc_tier = 'tier3_lookalike'  then 'lookalike'
            when org_type  = 'FQHC'             then 'fqhc'
            when org_type  = 'COMMUNITY_BH'     then 'community_bh'
            when org_type  = 'BH_SPECIALTY'     then 'bh_specialty'
            when org_type  = 'SUD'              then 'sud'
            else 'community'
        end as entity_key
    from {{ ref('org_npi_map') }}
    where in_doge = true
      and org_state = 'FL'
),

-- One stg_doge scan: distinct servicing_npi × billing_npi × period_month
-- filtered to known FL BH billing NPIs only
npi_months as (
    select distinct
        d.period_month,
        left(d.period_month, 4)         as period_year,
        cast(d.servicing_npi as string) as servicing_npi,
        cast(d.billing_npi  as string)  as billing_npi
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    where d.servicing_npi is not null
      and d.period_month >= '2019-01'
      and cast(d.billing_npi as string) in (select billing_npi from npi_entities)
),

npi_months_entity as (
    select
        nm.period_month,
        nm.period_year,
        nm.servicing_npi,
        coalesce(ne.entity_key, 'community') as entity_key
    from npi_months nm
    left join npi_entities ne on ne.billing_npi = nm.billing_npi
),

-- Month-pairs per entity: was this NPI active in both month m and m+1?
month_pairs as (
    select
        a.period_year,
        a.entity_key,
        a.period_month,
        count(distinct a.servicing_npi) as base_npis,
        count(distinct b.servicing_npi) as retained_npis
    from npi_months_entity a
    left join npi_months_entity b
        on  b.servicing_npi = a.servicing_npi
        and b.entity_key    = a.entity_key
        and b.period_month  = format_date(
                '%Y-%m',
                date_add(parse_date('%Y-%m', a.period_month), interval 1 month))
    group by 1, 2, 3
),

-- Same month-pairs pooled across all entities for market baseline
market_pairs as (
    select
        a.period_year,
        a.period_month,
        count(distinct a.servicing_npi) as base_npis,
        count(distinct b.servicing_npi) as retained_npis
    from npi_months_entity a
    left join npi_months_entity b
        on  b.servicing_npi = a.servicing_npi
        and b.period_month  = format_date(
                '%Y-%m',
                date_add(parse_date('%Y-%m', a.period_month), interval 1 month))
    group by 1, 2
),

entity_rates as (
    select
        period_year,
        entity_key,
        round(avg(safe_divide(retained_npis, base_npis)) * 100, 2) as retention_pct,
        round(avg(base_npis), 0)                                    as avg_npis
    from month_pairs
    where base_npis > 0
    group by 1, 2
),

market_rates as (
    select
        period_year,
        round(avg(safe_divide(retained_npis, base_npis)) * 100, 2) as mkt_retention_pct
    from market_pairs
    where base_npis > 0
    group by 1
)

select
    e.entity_key,
    cast(e.period_year as int64)                                   as period_year,
    e.retention_pct,
    e.avg_npis,
    m.mkt_retention_pct,
    round(safe_divide(e.retention_pct, m.mkt_retention_pct), 4)   as commitment_index
from entity_rates  e
join market_rates  m using (period_year)
order by e.entity_key, e.period_year
