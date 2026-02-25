{{
  config(
    materialized='view',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- TML rows for current run: filter by state_code and product. Unified landing has state, product columns.
-- See docs/MEDICAID_NPI_UNIFIED_LANDING.md.
select *
from {{ source('landing_medicaid_npi', 'stg_tml') }}
{% if var('use_unified_landing', false) %}
where coalesce(cast(program_state as string), 'FL') = '{{ var("state_code", "FL") }}'
  and coalesce(cast(product as string), 'medicaid') = '{{ var("product", "medicaid") }}'
{% endif %}
