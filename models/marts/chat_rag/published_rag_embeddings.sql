{{
  config(
    materialized='incremental',
    unique_key='id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
  )
}}

-- Chat-server mart: published RAG embeddings.
-- Source: landing_rag.rag_published_embeddings (replica of RAG PostgreSQL rag_published_embeddings).
-- Contract: CONTRACT_DBT_RAG.md Section 3. Sync reads this mart and loads into chat server vector DB + PostgreSQL.

select
  id,
  document_id,
  source_type,
  source_id,
  embedding,
  model,
  created_at,
  text,
  page_number,
  paragraph_index,
  section_path,
  chapter_path,
  summary,
  document_filename,
  document_display_name,
  document_authority_level,
  document_effective_date,
  document_termination_date,
  document_payer,
  document_state,
  document_program,
  document_status,
  document_created_at,
  document_review_status,
  document_reviewed_at,
  document_reviewed_by,
  content_sha,
  updated_at,
  source_verification_status
from {{ source('landing_rag', 'rag_published_embeddings') }}
{% if is_incremental() %}
where updated_at > (select coalesce(max(updated_at), timestamp('1970-01-01')) from {{ this }})
{% endif %}