{{
  config(
    materialized='table',
  )
}}

-- Chat-server mart: PHI audit log. Source: landing stg_phi_audit_log.
select
  event_id,
  ts,
  correlation_id,
  thread_id,
  event_type,
  phi_types,
  phi_count,
  stage,
  model_used,
  action_taken,
  hipaa_mode_active,
  baa_available
from {{ ref('stg_phi_audit_log') }}
