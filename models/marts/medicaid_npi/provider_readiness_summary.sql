{{
  config(
    enabled=false,
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- DISABLED 2026-04-23: Scanned 14.18 TiB per run (~$88). Zero non-dbt reads in 30d.

-- Provider readiness aggregated by billing_npi. One row per billing org.
-- Percentages: pct_ready_today, pct_ready_3mo.

select
  report_date,
  billing_npi,
  count(distinct npi) as provider_count,
  countif(fl_billing_npi) as fl_billing_provider_count,
  countif(eligible_today) as ready_today_count,
  countif(eligible_3mo) as ready_3mo_count,
  safe_divide(countif(eligible_today), count(distinct npi)) as pct_ready_today,
  safe_divide(countif(eligible_3mo), count(distinct npi)) as pct_ready_3mo,
  sum(claim_count) as total_claim_count,
  sum(total_paid) as total_paid,
  sum(beneficiary_count) as total_beneficiary_count
from {{ ref('provider_readiness') }}
group by report_date, billing_npi
