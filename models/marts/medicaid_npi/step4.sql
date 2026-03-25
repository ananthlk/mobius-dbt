{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 4: Raw address validation flags (B1, B2, B3, orphan) per (billing_npi, servicing_npi).
-- Self-sufficient with org/provider names and step_explanation. See docs/FL_MEDICAID_NPI_STEP_OUTPUTS.md.

with base as (
  select * from {{ ref('address_validation_fl') }}
),
billing_org as (
  select billing_npi, org_name as billing_org_name
  from {{ ref('organizations') }}
),
servicing_names as (
  select
    cast(npi as string) as npi,
    coalesce(
      nullif(trim(coalesce(provider_organization_name_legal_business_name, '')), ''),
      nullif(trim(concat(coalesce(trim(provider_last_name_legal_name), ''), ', ', coalesce(trim(provider_first_name), ''))), ','),
      'Unknown'
    ) as servicing_provider_name
  from {{ ref('nppes_run') }}
)
select
  b.billing_npi,
  coalesce(o.billing_org_name, 'Unknown') as billing_org_name,
  b.servicing_npi,
  coalesce(s.servicing_provider_name, 'Unknown') as servicing_provider_name,
  b.issue_b1,
  b.issue_b2,
  b.issue_b3,
  b.is_orphan,
  trim(
    concat(
      case when b.issue_b1 then 'B1: NPPES vs PML address mismatch. ' else '' end,
      case when b.issue_b2 then 'B2: Mailing differs from practice. ' else '' end,
      case when b.issue_b3 then 'B3: Org outlier (practice differs from org mode). ' else '' end,
      case when b.is_orphan then 'Orphan: no roster site. ' else '' end,
      case when not b.issue_b1 and not b.issue_b2 and not b.issue_b3 and not b.is_orphan then 'No address issues.' else '' end
    )
  ) as step_explanation
from base b
left join billing_org o on o.billing_npi = b.billing_npi
left join servicing_names s on s.npi = b.servicing_npi
