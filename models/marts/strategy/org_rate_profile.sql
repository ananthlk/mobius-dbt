{{
  config(
    materialized='table',
  )
}}

-- Org Rate Profile
-- Grain: one row per org_slug × ahca_category × period_month.
-- Computes org-level rpb and rpc per service line, then indexes against
-- the FL market rate for that same category × month.
-- Index = 1.0 means at market rate, >1.0 = above, <1.0 = below.

with bh_codes as (
    select hcpcs_code, ahca_category, primary_metric
    from {{ ref('stg_bh_codes') }}
),

fl_servicing_npis as (
    select distinct cast(npi as string) as npi
    from {{ source('nppes_public', 'npi_raw') }}
    where npi is not null
      and provider_business_practice_location_address_state_name = 'FL'
),

org_map as (
    select billing_npi, org_slug
    from (
        select
            cast(billing_npi as string) as billing_npi,
            org_slug,
            row_number() over (partition by billing_npi order by count(*) desc) as rn
        from {{ ref('org_npi_map') }}
        group by 1, 2
    )
    where rn = 1
),

-- Org-level claims by ahca_category × month
org_category as (
    select
        coalesce(om.org_slug, concat('npi-', cast(d.billing_npi as string))) as org_slug,
        bh.ahca_category,
        bh.primary_metric,
        d.period_month,
        sum(cast(d.beneficiary_count as int64))  as total_beneficiaries,
        sum(cast(d.claim_count       as int64))  as total_claims,
        sum(cast(d.total_paid        as float64)) as total_paid
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    inner join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
    inner join fl_servicing_npis fl on fl.npi = cast(d.servicing_npi as string)
    left join org_map om on om.billing_npi = cast(d.billing_npi as string)
    where d.servicing_npi is not null
      and d.billing_npi   is not null
      and d.period_month   is not null
    group by 1, 2, 3, 4
),

-- Market-level rates by ahca_category × month (from fl_bh_market_monthly)
market_rates as (
    select
        ahca_category,
        period_month,
        sum(total_beneficiaries) as mkt_beneficiaries,
        sum(total_claims)        as mkt_claims,
        sum(total_paid)          as mkt_paid,
        safe_divide(sum(total_paid), sum(total_beneficiaries)) as mkt_rate_per_beneficiary,
        safe_divide(sum(total_paid), sum(total_claims))        as mkt_rate_per_claim
    from {{ ref('fl_bh_market_monthly') }}
    group by 1, 2
)

select
    oc.org_slug,
    oc.ahca_category,
    oc.primary_metric,
    oc.period_month,
    left(oc.period_month, 4) as period_year,

    -- Org volumes
    oc.total_beneficiaries,
    oc.total_claims,
    oc.total_paid,

    -- Org rates
    safe_divide(oc.total_paid, oc.total_beneficiaries) as org_rate_per_beneficiary,
    safe_divide(oc.total_paid, oc.total_claims)        as org_rate_per_claim,

    -- Market rates
    mr.mkt_rate_per_beneficiary,
    mr.mkt_rate_per_claim,

    -- Rate index: org rate / market rate
    -- Uses primary_metric to pick the relevant rate for indexing
    case
        when oc.primary_metric = 'rpb' then
            safe_divide(
                safe_divide(oc.total_paid, oc.total_beneficiaries),
                mr.mkt_rate_per_beneficiary
            )
        else
            safe_divide(
                safe_divide(oc.total_paid, oc.total_claims),
                mr.mkt_rate_per_claim
            )
    end as rate_index,

    -- Both indexes available regardless of primary
    safe_divide(
        safe_divide(oc.total_paid, oc.total_beneficiaries),
        mr.mkt_rate_per_beneficiary
    ) as rpb_index,
    safe_divide(
        safe_divide(oc.total_paid, oc.total_claims),
        mr.mkt_rate_per_claim
    ) as rpc_index,

    -- Org share of this category's market
    safe_divide(oc.total_paid, mr.mkt_paid) as category_paid_share,
    safe_divide(oc.total_beneficiaries, mr.mkt_beneficiaries) as category_bene_share

from org_category oc
left join market_rates mr
    on mr.ahca_category = oc.ahca_category
    and mr.period_month = oc.period_month
