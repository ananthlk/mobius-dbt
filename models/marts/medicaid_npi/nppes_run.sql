{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- NPPES restricted to current run state (practice_state = var state_code). Foundation for state-scoped analyses.
-- Replaces nppes_fl; use var('state_code') to switch state.

select *
from {{ ref('nppes') }}
where practice_state = '{{ var("state_code", "FL") }}'
