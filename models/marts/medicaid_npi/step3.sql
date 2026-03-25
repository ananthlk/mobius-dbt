{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 3: Enrollment status (in_nppes, in_pml, eligible_today, eligible_3mo) per roster row.
-- Self-sufficient with org_name, npi_provider_name, step_explanation. See docs/FL_MEDICAID_NPI_STEP_OUTPUTS.md.

with base as (
  select * from {{ ref('provider_readiness') }}
),
org_from_nppes as (
  select
    cast(npi as string) as npi,
    coalesce(
      nullif(trim(coalesce(provider_organization_name_legal_business_name, '')), ''),
      nullif(trim(concat(coalesce(trim(provider_last_name_legal_name), ''), ', ', coalesce(trim(provider_first_name), ''))), ','),
      'Unknown'
    ) as org_name
  from {{ ref('nppes_run') }}
),
org_from_billing as (
  select billing_npi, org_name
  from {{ ref('organizations') }}
),
npi_names as (
  select
    cast(npi as string) as npi,
    coalesce(
      nullif(trim(coalesce(provider_organization_name_legal_business_name, '')), ''),
      nullif(trim(concat(coalesce(trim(provider_last_name_legal_name), ''), ', ', coalesce(trim(provider_first_name), ''))), ','),
      'Unknown'
    ) as npi_provider_name
  from {{ ref('nppes_run') }}
)
select
  b.report_date,
  b.org_id,
  b.sub_org_id,
  b.source_type,
  b.billing_npi,
  b.npi,
  coalesce(
    case when b.source_type = 'address' then o_nppes.org_name end,
    case when b.source_type = 'billing_npi' then o_bill.org_name end,
    'Unknown'
  ) as org_name,
  coalesce(n.npi_provider_name, 'Unknown') as npi_provider_name,
  b.fl_billing_npi,
  b.in_nppes,
  b.in_pml,
  b.in_ppl,
  b.eligible_today,
  b.eligible_3mo,
  b.reason_today,
  b.reason_3mo,
  b.claim_count,
  b.total_paid,
  b.beneficiary_count,
  'Enrollment status: ' || b.reason_today || '. 3‑month horizon: ' || b.reason_3mo || '.' as step_explanation
from base b
left join org_from_nppes o_nppes on o_nppes.npi = b.org_id and b.source_type = 'address'
left join org_from_billing o_bill on o_bill.billing_npi = b.org_id and b.source_type = 'billing_npi'
left join npi_names n on n.npi = b.npi
