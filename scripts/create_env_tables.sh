#!/usr/bin/env bash
# Create landing and mart tables in each BigQuery env dataset (dev, staging, prod).
# Run after create_bq_datasets.sh. Requires: bq CLI and auth.
#
# Creates in each landing_rag_{env}: rag_published_embeddings
# Creates in each mobius_rag_{env}: sync_runs (published_rag_embeddings is created by dbt run)

set -e
BQ_PROJECT="${BQ_PROJECT:-mobiusos-new}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Creating tables in project: $BQ_PROJECT"

for env in dev staging prod; do
  LANDING_DATASET="landing_rag_${env}"
  MART_DATASET="mobius_rag_${env}"

  echo "  [$env] Creating ${LANDING_DATASET}.rag_published_embeddings..."
  bq query --project_id="$BQ_PROJECT" --use_legacy_sql=false --nouse_cache "
    CREATE TABLE IF NOT EXISTS \`${BQ_PROJECT}.${LANDING_DATASET}.rag_published_embeddings\` (
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
    OPTIONS(description = 'Landing table for RAG published embeddings. Replica of RAG PostgreSQL. Populated by ingest; read by dbt mart.');
  "

  echo "  [$env] Creating ${MART_DATASET}.sync_runs..."
  bq query --project_id="$BQ_PROJECT" --use_legacy_sql=false --nouse_cache "
    CREATE TABLE IF NOT EXISTS \`${BQ_PROJECT}.${MART_DATASET}.sync_runs\` (
      run_id STRING NOT NULL,
      started_at TIMESTAMP NOT NULL,
      finished_at TIMESTAMP,
      mart_rows_read INT64,
      postgres_rows_written INT64,
      vector_rows_upserted INT64,
      status STRING NOT NULL,
      error_message STRING
    )
    OPTIONS(description = 'Sync run audit: mart to Chat. One row per sync_mart_to_chat.py run.');
  "

  echo "  [$env] Creating ${MART_DATASET}.sync_watermark..."
  bq query --project_id="$BQ_PROJECT" --use_legacy_sql=false --nouse_cache "
    CREATE TABLE IF NOT EXISTS \`${BQ_PROJECT}.${MART_DATASET}.sync_watermark\` (
      id INT64 NOT NULL,
      last_updated_at TIMESTAMP
    )
    OPTIONS(description = 'Incremental sync: last mart updated_at synced to Chat. Single row id=1.');
  "
done

echo "Done. published_rag_embeddings in each mobius_rag_* is created by 'dbt run' when you set BQ_DATASET=mobius_rag_{env}."
