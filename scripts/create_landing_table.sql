-- Create landing table for RAG published embeddings (mobiusos-new.landing_rag.rag_published_embeddings).
-- Run this in BigQuery Console if the table does not exist yet. Schema matches CONTRACT_DBT_RAG / dbt source.
-- After creation, run ingestion (RAG Postgres → this table) or leave empty and run dbt run.

CREATE TABLE IF NOT EXISTS `mobiusos-new.landing_rag.rag_published_embeddings` (
  id STRING NOT NULL,
  document_id STRING NOT NULL,
  source_type STRING NOT NULL,
  source_id STRING NOT NULL,
  embedding ARRAY<FLOAT64>,
  model STRING,
  created_at TIMESTAMP NOT NULL,
  text STRING,
  page_number INT64,
  paragraph_index INT64,
  section_path STRING,
  chapter_path STRING,
  summary STRING,
  document_filename STRING,
  document_display_name STRING,
  document_authority_level STRING,
  document_effective_date STRING,
  document_termination_date STRING,
  document_payer STRING,
  document_state STRING,
  document_program STRING,
  document_status STRING,
  document_created_at TIMESTAMP,
  document_review_status STRING,
  document_reviewed_at TIMESTAMP,
  document_reviewed_by STRING,
  content_sha STRING NOT NULL,
  updated_at TIMESTAMP NOT NULL,
  source_verification_status STRING
)
OPTIONS(
  description = "Landing table for RAG published embeddings. Replica of RAG PostgreSQL rag_published_embeddings. Populated by ingestion job; read by dbt mart published_rag_embeddings."
);
  