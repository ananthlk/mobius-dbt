{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- NPPES provider data from BigQuery public dataset.
-- Source: bigquery-public-data.nppes.npi_optimized (no load; query directly).
-- Use for NPI readiness score and provider lookup (FL Medicaid NPI Initiative).

select *
from {{ source('nppes_public', 'npi_optimized') }}
