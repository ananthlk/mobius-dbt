{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Ghost billing: servicing NPIs that BILL under the org (in DOGE) but have WEAK address/roster match (low confidence).
-- Definition: Billing under org + confidence_score < 40 = "ghost" (we cannot confidently tie them to that location).
-- Used by Provider Roster Credentialing report. See docs/FL_MEDICAID_NPI_STEP_OUTPUTS.md.

with doge_recent as (
  select
    cast(billing_npi as string) as billing_npi,
    cast(servicing_npi as string) as servicing_npi,
    sum(coalesce(claim_count, 0)) as claim_count,
    sum(coalesce(total_paid, 0)) as total_paid
  from {{ ref('stg_doge') }}
  where billing_npi is not null
    and servicing_npi is not null
    and trim(cast(servicing_npi as string)) != ''
    and substr(safe_cast(period_month as string), 1, 6) >= format_date('%Y%m', date_sub(current_date('America/New_York'), interval 12 month))
  group by 1, 2
),
roster_weak as (
  select
    org_npi,
    servicing_npi,
    servicing_provider_name,
    confidence_score,
    total_claims_3yr
  from {{ ref('bh_roster_readiness') }}
  where coalesce(confidence_score, 0) < 40
    and coalesce(total_claims_3yr, 0) > 0
)
select
  r.org_npi as billing_npi,
  r.servicing_npi,
  r.servicing_provider_name,
  r.confidence_score,
  coalesce(d.claim_count, 0) as claim_count,
  coalesce(d.total_paid, 0) as total_paid
from roster_weak r
inner join doge_recent d
  on r.org_npi = d.billing_npi
  and r.servicing_npi = d.servicing_npi
where coalesce(d.claim_count, 0) > 0
order by d.total_paid desc
