-- Create sync_runs table in BigQuery for tracking mart → Chat sync runs.
-- Run this in BigQuery Console (Query editor, project mobiusos-new) once per dataset (dev/prod).
-- After creation, the sync script (sync_mart_to_chat.py) writes one row per run.

CREATE TABLE IF NOT EXISTS `mobiusos-new.mobius_rag_dev.sync_runs` (
  run_id STRING NOT NULL,
  started_at TIMESTAMP NOT NULL,
  finished_at TIMESTAMP,
  mart_rows_read INT64,
  postgres_rows_written INT64,
  vector_rows_upserted INT64,
  status STRING NOT NULL,
  error_message STRING
)
OPTIONS(
  description = "Sync run audit: mart → Chat (Postgres + Vertex). One row per sync_mart_to_chat.py run."
);

-- For prod dataset:
-- CREATE TABLE IF NOT EXISTS `mobiusos-new.mobius_rag.sync_runs` (...same schema...);
