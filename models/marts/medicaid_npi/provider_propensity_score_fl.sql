{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Propensity score: 0–100 likelihood of successful/continued billing.
-- Combines enrollment, address, taxonomy, and utilization signals.

with base as (
  select
    r.billing_npi,
    r.servicing_npi as npi,
    r.status_flag,
    r.eligible_today,
    r.eligible_3mo,
    r.fl_billing_npi,
    r.issue_b1,
    r.issue_b2,
    r.issue_b3,
    r.issue_c1,
    r.issue_c2,
    r.issue_c3,
    r.issue_c4,
    r.issue_d,
    r.issue_f,
    r.tml_aligned,
    r.total_paid,
    r.claim_count,
    r.beneficiary_count
  from {{ ref('provider_readiness_report') }} r
),
scored as (
  select
    billing_npi,
    npi,
    status_flag,
    total_paid,
    claim_count,
    beneficiary_count,
    -- Enrollment component (0–40): eligible_today+3mo=40, eligible_today=30, eligible_3mo=20, else 0
    case
      when not fl_billing_npi then 0
      when eligible_today and eligible_3mo then 40
      when eligible_today then 30
      when eligible_3mo then 20
      else 0
    end as enrollment_score,
    -- Address component (0–15): no B1/B3 = 15. B2 (practice vs mailing) = info only.
    case when not (issue_b1 or issue_b3) then 15 else 0 end as address_score,
    -- Taxonomy component (0–30): TML aligned + no C/D/F = 30
    case
      when tml_aligned and not (issue_c2 or issue_c3 or issue_c4 or issue_d or issue_f) then 30
      when tml_aligned then 20
      when not issue_c1 then 10
      else 0
    end as taxonomy_score,
    -- Utilization component (0–15): not HCPCS outlier = 15
    case when not issue_d then 15 else 0 end as utilization_score
  from base
)
select
  billing_npi,
  npi,
  status_flag,
  enrollment_score,
  address_score,
  taxonomy_score,
  utilization_score,
  least(100, enrollment_score + address_score + taxonomy_score + utilization_score) as propensity_score,
  total_paid,
  claim_count,
  beneficiary_count
from scored
