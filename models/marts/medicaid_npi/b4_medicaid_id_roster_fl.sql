{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- B4: Roster of all Medicaid IDs per NPI from PML; flag permissible (exists in PML, contract valid).
-- Validate against NPPES "other provider identifier" for Medicaid when that column is available.
-- See docs/B4_MEDICAID_ID_ROSTER.md.

with pml as (
  select
    cast(npi as string) as npi,
    cast(medicaid_provider_id as string) as medicaid_provider_id,
    contract_effective_date,
    contract_end_date
  from {{ ref('medicaid_provider_ids') }}
  where npi is not null and medicaid_provider_id is not null
    and trim(cast(medicaid_provider_id as string)) != ''
),
roster as (
  select
    npi,
    medicaid_provider_id,
    max(contract_effective_date) as latest_contract_effective_date,
    max(contract_end_date) as latest_contract_end_date,
    logical_or(
      current_date('America/New_York') between coalesce(contract_effective_date, date '1900-01-01')
        and coalesce(contract_end_date, date '9999-12-31')
    ) as b4_permissible
  from pml
  group by npi, medicaid_provider_id
)
select
  npi,
  medicaid_provider_id,
  latest_contract_effective_date,
  latest_contract_end_date,
  b4_permissible
from roster
