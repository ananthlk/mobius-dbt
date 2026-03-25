{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Step 5: Medicaid ID status per NPI (b4 counts and flags).
-- Self-sufficient with npi_provider_name and step_explanation. See docs/FL_MEDICAID_NPI_STEP_OUTPUTS.md.

with base as (
  select * from {{ ref('b4_npi_medicaid_status_fl') }}
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
  b.npi,
  coalesce(n.npi_provider_name, 'Unknown') as npi_provider_name,
  b.b4_medicaid_id_count,
  b.b4_has_permissible_id,
  b.b4_no_medicaid_id_in_pml,
  concat(
    'NPI has ', cast(b.b4_medicaid_id_count as string), ' Medicaid ID(s) in PML. ',
    case when b.b4_has_permissible_id then 'Has permissible ID.' else 'No permissible ID.' end
  ) as step_explanation
from base b
left join npi_names n on n.npi = b.npi
