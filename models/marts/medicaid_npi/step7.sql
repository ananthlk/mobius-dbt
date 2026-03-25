{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 7: Taxonomy validation (C1–C4, D, F) per (billing_npi, servicing_npi).
-- Self-sufficient with billing_org_name, servicing_provider_name, step_explanation.
-- See docs/FL_MEDICAID_NPI_STEP_OUTPUTS.md.

with base as (
  select * from {{ ref('taxonomy_validation_fl') }}
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
  b.issue_c1,
  b.issue_c2,
  b.issue_c3,
  b.issue_c4,
  b.issue_d,
  b.issue_f,
  trim(
    concat(
      case when b.issue_c1 then 'C1: Primary taxonomy not in TML. ' else '' end,
      case when b.issue_c2 then 'C2: NPPES vs PML taxonomy mismatch. ' else '' end,
      case when b.issue_c3 then 'C3: Org taxonomy outlier. ' else '' end,
      case when b.issue_c4 then 'C4: Entity/name mismatch. ' else '' end,
      case when b.issue_d then 'D: Billed HCPCS outlier for taxonomy. ' else '' end,
      case when b.issue_f then 'F: Entity type/name mismatch. ' else '' end,
      case when not coalesce(b.issue_c1, false) and not coalesce(b.issue_c2, false)
            and not coalesce(b.issue_c3, false) and not coalesce(b.issue_c4, false)
            and not coalesce(b.issue_d, false) and not coalesce(b.issue_f, false)
        then 'No taxonomy validation issues.' else '' end
    )
  ) as step_explanation
from base b
left join billing_org o on o.billing_npi = b.billing_npi
left join servicing_names s on s.npi = b.servicing_npi
