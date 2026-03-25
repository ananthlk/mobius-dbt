{{
  config(
    materialized='view',
    schema=env_var('BQ_LANDING_DATASET', 'landing_rag'),
  )
}}

-- Staging: LLM config versions from landing (PG replica).
select
  config_sha,
  config_json,
  cast(created_at as timestamp) as created_at,
  created_by,
  notes,
  model,
  provider,
  cast(prompt_count as int64) as prompt_count
from {{ source('landing_llm', 'llm_config_versions') }}
