{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Executive summary: aggregate metrics for report_date.
-- Feeds mockup "Executive Summary" section.

with report as (
  select * from {{ ref('provider_readiness_report') }}
),
summary as (
  select * from {{ ref('provider_readiness_summary') }}
),
base as (
  select
    (select max(report_date) from summary limit 1) as report_date,
    (select count(distinct billing_npi) from report where fl_billing_npi) as total_billing_orgs,
    (select count(distinct servicing_npi) from report) as total_servicing_providers,
    (select sum(total_paid) from report) as total_billed_volume,
    (select countif(status_flag = 'Green') from report) as green_count,
    (select countif(status_flag = 'Yellow') from report) as yellow_count,
    (select countif(status_flag = 'Red') from report) as red_count,
    (select countif(issue_b1 or issue_b2 or issue_b3) from report) as issue_b_count,
    (select countif(issue_c1 or issue_c2 or issue_c3 or issue_c4) from report) as issue_c_count,
    (select countif(issue_d) from report) as issue_d_count,
    (select countif(issue_f) from report) as issue_f_count,
    (select countif(reason_today in ('not_in_pml','pml_contract_ended','pml_contract_not_started','pml_expires_before_3mo','not_in_pml_and_not_in_ppl','in_ppl_pending')) from report) as issue_a_count
)
select
  report_date,
  total_billing_orgs,
  total_servicing_providers,
  total_billed_volume,
  green_count,
  yellow_count,
  red_count,
  safe_divide(green_count, total_servicing_providers) as pct_green,
  safe_divide(yellow_count, total_servicing_providers) as pct_yellow,
  safe_divide(red_count, total_servicing_providers) as pct_red,
  issue_a_count as issue_a_enrollment_count,
  issue_b_count,
  issue_c_count,
  issue_d_count,
  issue_f_count
from base
