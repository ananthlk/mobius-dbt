{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Phase 3: Validation on union. Joins roster_reconciliation_union_fl with NPPES for basic NPI checks.
-- Full step2-step9 validation would require parameterizing existing models to accept this roster.
-- This model provides: in_nppes, reconciliation_status per NPI.

with union_roster as (
  select upload_id, org_name, npi, reconciliation_status
  from {{ ref('roster_reconciliation_union_fl') }}
),
nppes_check as (
  select
    lpad(trim(cast(npi as string)), 10, '0') as npi_norm
  from {{ ref('nppes_run') }}
)
select
  u.upload_id,
  u.org_name,
  u.npi,
  u.reconciliation_status,
  (n.npi_norm is not null) as in_nppes
from union_roster u
left join nppes_check n on lpad(trim(cast(u.npi as string)), 10, '0') = n.npi_norm
