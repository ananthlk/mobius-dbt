{{
  config(
    materialized='table',
  )
}}

-- stg_bh_codes: one row per hcpcs_code (code-level attributes only).
-- Wraps the fl_bh_code_reference seed with service_line alias.

select
    hcpcs_code,
    description,
    ahca_category,
    ahca_category as service_line,
    coalesce(primary_metric, 'rpb') as primary_metric,
    care_stage
from {{ ref('fl_bh_code_reference') }}
