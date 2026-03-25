{{
  config(
    materialized='view',
    schema=env_var('BQ_LANDING_DATASET', 'landing_rag'),
  )
}}

-- Staging: PHI audit log from landing (PG replica).
select
  cast(event_id as string) as event_id,
  cast(ts as timestamp) as ts,
  correlation_id,
  thread_id,
  event_type,
  phi_types,
  cast(phi_count as int64) as phi_count,
  stage,
  model_used,
  action_taken,
  cast(hipaa_mode_active as boolean) as hipaa_mode_active,
  cast(baa_available as boolean) as baa_available
from {{ source('landing_llm', 'phi_audit_log') }}
