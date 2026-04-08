{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
    tags=['periodic'],
    enabled=var('run_periodic', false),
  )
}}

-- Assessed HCPCS benchmark table — ALL peer groups × dimension values.
-- Joins fl_bh_code_reference (70 BH codes) with hcpcs_rate_benchmarks_v2 (monthly-grain),
-- then applies rules to classify each code's benchmark quality per dimension.
--
-- Output: one row per hcpcs_code × peer_group × dimension_value
--   with P25/P50/P75 in the PRIMARY metric (rpb or ppc),
--   plus benchmark_status, confidence, and recommendation.
--
-- Consumers: financial strategy report pipeline, org radar, dashboard, API.
-- All assessment logic lives HERE — no Python-side rules needed.

with ref as (
    select
        hcpcs_code,
        description,
        ahca_category,
        primary_metric
    from {{ source('financial_reference', 'fl_bh_code_reference') }}
),

-- All distinct peer_group × dimension_value combos in the benchmark table
dimensions as (
    select distinct peer_group, dimension_value
    from {{ ref('hcpcs_rate_benchmarks_v2') }}
),

-- Cross join: every code × every dimension combo
ref_x_dim as (
    select
        r.hcpcs_code,
        r.description,
        r.ahca_category,
        r.primary_metric,
        d.peer_group,
        d.dimension_value
    from ref r
    cross join dimensions d
),

bench as (
    select *
    from {{ ref('hcpcs_rate_benchmarks_v2') }}
),

-- Known code classifications
code_flags as (
    select hcpcs_code, flag
    from unnest([
        struct('90833' as hcpcs_code, 'add_on' as flag),
        struct('90836', 'add_on'),
        struct('90838', 'add_on'),
        struct('90785', 'add_on'),
        struct('96127', 'zero_pay_by_design')
    ])
),

joined as (
    select
        r.hcpcs_code,
        r.description,
        r.ahca_category,
        r.primary_metric,
        r.peer_group,
        r.dimension_value,
        case r.primary_metric
            when 'rpb' then '$/bene/mo'
            when 'ppc' then '$/claim'
            else '?'
        end as unit,

        coalesce(b.n_org_months, 0)        as n_org_months,
        coalesce(b.org_count, 0)           as n_orgs,
        coalesce(b.svc_npi_count, 0)       as svc_npi_count,
        coalesce(b.total_claims, 0)        as total_claims,
        coalesce(b.total_paid, 0)          as total_paid,
        coalesce(b.total_beneficiaries, 0) as total_beneficiaries,

        -- Primary metric P25/P50/P75
        case r.primary_metric
            when 'rpb' then b.p25_revenue_per_bene
            else b.p25_payment_per_claim
        end as p25,
        case r.primary_metric
            when 'rpb' then b.p50_revenue_per_bene
            else b.p50_payment_per_claim
        end as p50,
        case r.primary_metric
            when 'rpb' then b.p75_revenue_per_bene
            else b.p75_payment_per_claim
        end as p75,

        -- All KPI percentiles (for downstream consumers that need them)
        b.p25_payment_per_claim, b.p50_payment_per_claim, b.p75_payment_per_claim,
        b.p25_revenue_per_bene,  b.p50_revenue_per_bene,  b.p75_revenue_per_bene,
        b.p25_claims_per_bene,   b.p50_claims_per_bene,   b.p75_claims_per_bene,
        b.p25_bene_per_clinician, b.p50_bene_per_clinician, b.p75_bene_per_clinician,

        coalesce(cf.flag, '') as code_flag,

        -- Derived signals for assessment
        case
            when b.n_org_months is null then true
            else false
        end as has_no_data,

        case
            when b.total_paid = 0 then true
            else false
        end as is_zero_paid,

        case
            when r.primary_metric = 'ppc'
                 and b.p25_payment_per_claim is not null
                 and b.p25_payment_per_claim < 1.0
                 and b.p50_payment_per_claim > 10.0
            then true
            else false
        end as is_bimodal

    from ref_x_dim r
    left join bench b
        on  r.hcpcs_code      = b.hcpcs_code
        and r.peer_group       = b.peer_group
        and (r.dimension_value = b.dimension_value
             or (r.dimension_value is null and b.dimension_value is null))
    left join code_flags cf on r.hcpcs_code = cf.hcpcs_code
),

assessed as (
    select
        *,
        -- IQR
        case when p25 is not null and p75 is not null
            then round(p75 - p25, 2)
            else null
        end as iqr,

        -- IQR / P50 ratio
        case when p50 is not null and p50 > 0 and p25 is not null and p75 is not null
            then round((p75 - p25) / p50, 2)
            else null
        end as iqr_p50_ratio,

        -- ── benchmark_status ──
        case
            when has_no_data then 'no_data'
            when is_zero_paid then 'unusable'
            when code_flag = 'zero_pay_by_design' then 'unusable'
            when n_orgs <= 2 then 'unusable'
            when p50 = 0 then 'unusable'
            when code_flag = 'add_on' and n_orgs < 5 then 'add_on_thin'
            when code_flag = 'add_on' then 'add_on'
            when is_bimodal then 'usable_bimodal'
            when n_orgs <= 5 then 'thin'
            when p50 > 0 and (p75 - p25) / p50 > 3.0 then 'usable_wide'
            else 'usable'
        end as benchmark_status,

        -- ── confidence ──
        case
            when has_no_data then 'none'
            when is_zero_paid then 'none'
            when code_flag = 'zero_pay_by_design' then 'none'
            when n_orgs <= 2 then 'none'
            when p50 = 0 then 'none'
            when n_org_months >= 100 and n_orgs >= 20 then 'high'
            when n_org_months >= 30  and n_orgs >= 5  then 'moderate'
            else 'low'
        end as confidence

    from joined
)

select
    hcpcs_code,
    description,
    ahca_category,
    primary_metric,
    peer_group,
    dimension_value,
    unit,
    benchmark_status,
    confidence,
    n_org_months,
    n_orgs,
    total_paid,
    p25, p50, p75, iqr, iqr_p50_ratio,

    -- Recommendation text
    case benchmark_status
        when 'no_data' then
            'Not benchmarkable — fewer than 3 orgs bill this code in this peer group.'
        when 'unusable' then
            case
                when is_zero_paid then
                    'Zero reimbursement observed. Code may be authorization-only or not actively paid.'
                when code_flag = 'zero_pay_by_design' then
                    'Screening code — $0 reimbursement by design. Not a revenue code.'
                when n_orgs <= 2 then
                    concat('Only ', cast(n_orgs as string), ' org(s) — no meaningful distribution.')
                when p50 = 0 then
                    'Median rate is $0.00 — most orgs receive no payment. Not benchmarkable.'
                else 'Unusable benchmark.'
            end
        when 'add_on_thin' then
            concat('Add-on code (billed with primary E&M). Only ', cast(n_orgs as string),
                   ' orgs. Rate is add-on differential, not standalone value. Use with caution.')
        when 'add_on' then
            case when is_bimodal then
                concat('Add-on code. Bimodal: some orgs bundle at $0, others pay separately. Use P50–P75 ($',
                       cast(p50 as string), '–$', cast(p75 as string), ') as actionable band.')
            else
                'Add-on code — rate reflects differential on top of primary E&M, not standalone reimbursement.'
            end
        when 'usable_bimodal' then
            concat('Bimodal — some orgs pay $0 (bundled under encounter codes), others pay standalone. ',
                   'P25 ($', cast(p25 as string), ') not meaningful. Use P50–P75 ($',
                   cast(p50 as string), '–$', cast(p75 as string), ').')
        when 'thin' then
            concat('Only ', cast(n_orgs as string), ' orgs (', cast(n_org_months as string),
                   ' org-months). Directionally useful but too thin for confident benchmarking.')
        when 'usable_wide' then
            concat('Wide spread (IQR/P50 = ', cast(iqr_p50_ratio as string),
                   'x). P50 reliable but P25–P75 is broad — org variation is real, not noise.')
        when 'usable' then
            case confidence
                when 'high' then
                    concat('Strong benchmark. ', cast(n_orgs as string), ' orgs, ',
                           cast(n_org_months as string), ' org-months. Use P25–P75 as confidence band.')
                when 'moderate' then
                    concat('Solid benchmark. ', cast(n_orgs as string), ' orgs, ',
                           cast(n_org_months as string), ' org-months. P50 primary, P25–P75 as range.')
                else
                    concat(cast(n_orgs as string), ' orgs, ', cast(n_org_months as string),
                           ' org-months. Directionally useful — verify against local context.')
            end
        else 'Unknown status.'
    end as recommendation,

    -- Pass-through all KPI percentiles for downstream
    p25_payment_per_claim, p50_payment_per_claim, p75_payment_per_claim,
    p25_revenue_per_bene,  p50_revenue_per_bene,  p75_revenue_per_bene,
    p25_claims_per_bene,   p50_claims_per_bene,   p75_claims_per_bene,
    p25_bene_per_clinician, p50_bene_per_clinician, p75_bene_per_clinician,

    -- Flags for filtering
    code_flag,
    is_bimodal,
    svc_npi_count,
    total_claims,
    total_beneficiaries

from assessed
order by peer_group, dimension_value, ahca_category, total_paid desc
