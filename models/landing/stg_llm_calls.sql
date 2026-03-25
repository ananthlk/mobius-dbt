{{
  config(
    materialized='view',
    schema=env_var('BQ_LANDING_DATASET', 'landing_rag'),
  )
}}

-- Staging: LLM calls from landing (PG replica). Cast to BQ types; omit synced_to_bq/synced_at.
select
  cast(call_id as string) as call_id,
  correlation_id,
  thread_id,
  cast(ts as timestamp) as ts,
  config_sha,
  model,
  provider,
  stage,
  tier,
  complexity,
  cast(is_ab_call as boolean) as is_ab_call,
  ab_variant,
  cast(success as boolean) as success,
  cast(is_rate_limit as boolean) as is_rate_limit,
  cast(is_fallback as boolean) as is_fallback,
  fallback_from,
  cast(completion_valid as boolean) as completion_valid,
  error_type,
  cast(latency_ms as int64) as latency_ms,
  cast(input_tokens as int64) as input_tokens,
  cast(output_tokens as int64) as output_tokens,
  cast(total_tokens as int64) as total_tokens,
  cast(cost_usd as float64) as cost_usd,
  cast(quality_score as float64) as quality_score,
  quality_source,
  cast(phi_detected as boolean) as phi_detected,
  cast(phi_scrubbed as boolean) as phi_scrubbed,
  phi_types,
  cast(prompt_len_chars as int64) as prompt_len_chars,
  cast(output_len_chars as int64) as output_len_chars,
  prompt_hash
from {{ source('landing_llm', 'llm_calls') }}
