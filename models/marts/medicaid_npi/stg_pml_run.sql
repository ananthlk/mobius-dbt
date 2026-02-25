{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- PML rows for current run. When use_unified_landing=true, filter by program_state/product; else all rows (run migration first for multi-state).
-- See docs/MEDICAID_NPI_UNIFIED_LANDING.md.
select *
from {{ source('landing_medicaid_npi', 'stg_pml') }}
{% if var('use_unified_landing', false) %}
where coalesce(cast(program_state as string), 'FL') = '{{ var("state_code", "FL") }}'
  and coalesce(cast(product as string), 'medicaid') = '{{ var("product", "medicaid") }}'
{% endif %}
