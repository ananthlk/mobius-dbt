{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- FL Medicaid taxonomy-level revenue rates (per-beneficiary low/mid/high, beneficiaries per provider).
-- Built from DOGE 2024 + roster taxonomy. Consumed by bh_roster_revenue_impact and Python/LLM.
-- State scope: FL (roster and DOGE allocation by taxonomy).

with roster_tax as (
  select
    org_npi,
    servicing_npi,
    trim(cast(provider_taxonomy_code as string)) as provider_taxonomy_code
  from {{ ref('bh_roster') }}
  where provider_taxonomy_code is not null and trim(cast(provider_taxonomy_code as string)) != ''
),

pair_tax_count as (
  select org_npi, servicing_npi, count(distinct provider_taxonomy_code) as n_tax
  from roster_tax
  group by 1, 2
),

doge_2024 as (
  select
    cast(billing_npi as string) as billing_npi,
    cast(servicing_npi as string) as servicing_npi,
    sum(coalesce(total_paid, 0)) as paid,
    sum(coalesce(beneficiary_count, 0)) as beneficiaries
  from {{ ref('stg_doge') }}
  where substr(safe_cast(period_month as string), 1, 4) = '2024'
    and servicing_npi is not null and trim(cast(servicing_npi as string)) != ''
  group by 1, 2
  having sum(coalesce(beneficiary_count, 0)) > 0
),

-- Allocate DOGE to taxonomy evenly when (org_npi, servicing_npi) has multiple taxonomies
doge_with_tax as (
  select
    d.billing_npi,
    d.servicing_npi,
    r.provider_taxonomy_code,
    d.paid / nullif(t.n_tax, 0) as paid_alloc,
    d.beneficiaries / nullif(t.n_tax, 0) as ben_alloc
  from doge_2024 d
  inner join roster_tax r
    on d.billing_npi = r.org_npi and d.servicing_npi = r.servicing_npi
  inner join pair_tax_count t
    on d.billing_npi = t.org_npi and d.servicing_npi = t.servicing_npi
),

-- Per-cell revenue per beneficiary (for percentiles)
cell_revenue_per_ben as (
  select
    provider_taxonomy_code,
    paid_alloc / nullif(ben_alloc, 0) as revenue_per_beneficiary
  from doge_with_tax
  where ben_alloc > 0
),

-- Per-taxonomy totals and provider count (for beneficiaries_per_provider)
taxonomy_totals as (
  select
    provider_taxonomy_code,
    sum(paid_alloc) as total_paid_2024,
    sum(ben_alloc) as total_beneficiaries_2024,
    count(distinct servicing_npi) as provider_count
  from doge_with_tax
  group by 1
  having sum(ben_alloc) > 0
),

-- Approx percentiles of revenue_per_beneficiary by taxonomy
taxonomy_quantiles as (
  select
    provider_taxonomy_code,
    approx_quantiles(revenue_per_beneficiary, 100)[offset(25)] as revenue_per_beneficiary_p25,
    approx_quantiles(revenue_per_beneficiary, 100)[offset(50)] as revenue_per_beneficiary_p50,
    approx_quantiles(revenue_per_beneficiary, 100)[offset(75)] as revenue_per_beneficiary_p75
  from cell_revenue_per_ben
  group by 1
),

fl_tml as (
  select distinct trim(cast(taxonomy_code as string)) as taxonomy_code
  from {{ source('landing_medicaid_npi', 'stg_tml') }}
  where taxonomy_code is not null and trim(cast(taxonomy_code as string)) != ''
)

select
  t.provider_taxonomy_code,
  round(q.revenue_per_beneficiary_p25, 2) as revenue_per_beneficiary_p25,
  round(q.revenue_per_beneficiary_p50, 2) as revenue_per_beneficiary_p50,
  round(q.revenue_per_beneficiary_p75, 2) as revenue_per_beneficiary_p75,
  round(t.total_paid_2024 / nullif(t.total_beneficiaries_2024, 0), 2) as revenue_per_beneficiary_avg,
  round(t.total_beneficiaries_2024 / nullif(t.provider_count, 0), 2) as beneficiaries_per_provider_median,
  t.provider_count,
  t.total_beneficiaries_2024,
  t.total_paid_2024,
  (tml.taxonomy_code is not null) as in_tml
from taxonomy_totals t
left join taxonomy_quantiles q on t.provider_taxonomy_code = q.provider_taxonomy_code
left join fl_tml tml on t.provider_taxonomy_code = tml.taxonomy_code
order by t.total_paid_2024 desc
