{{
  config(
    materialized='table',
  )
}}

-- Chat-server mart: prompts+LLM config version history. Source: landing stg_llm_config_versions.
select
  config_sha,
  config_json,
  created_at,
  created_by,
  notes,
  model,
  provider,
  prompt_count
from {{ ref('stg_llm_config_versions') }}
