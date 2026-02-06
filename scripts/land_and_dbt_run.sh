#!/usr/bin/env bash
# Run ingestion (RAG Postgres → BigQuery landing) then dbt run and dbt test.
# Use this as the single job to schedule (e.g. Cloud Scheduler, Composer).
# Loads .env from project root if present. Copy .env.example to .env and set origin/destination.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ -f .env ]]; then
  # Safe .env loader (no shell expansion).
  # Avoids corrupting URLs that contain '$@' (e.g. passwords ending with '$').
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    [[ -z "$_line" || "$_line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$_line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    fi
  done < .env
fi

if [[ -z "$POSTGRES_HOST" ]] || [[ -z "$POSTGRES_PASSWORD" ]]; then
  echo "Set POSTGRES_HOST and POSTGRES_PASSWORD (e.g. copy .env.example to .env and set origin/destination)."
  exit 1
fi

echo "=== 1. Ingest RAG PostgreSQL → BigQuery landing ==="
python scripts/ingest_rag_to_landing.py
echo ""

echo "=== 2. dbt run (build mart from landing) ==="
dbt run
echo ""

echo "=== 3. dbt test ==="
dbt test
echo ""

# Step 4: Sync mart → Chat (Postgres + Vertex) - optional; runs if Chat env vars are set
if [[ -n "$CHAT_DATABASE_URL" ]] && [[ -n "$VERTEX_INDEX_ID" ]]; then
  echo "=== 4. Sync mart → Chat (Postgres + Vertex) ==="
  python scripts/sync_mart_to_chat.py
  echo ""
else
  echo "=== 4. Sync mart → Chat: SKIPPED (set CHAT_DATABASE_URL, VERTEX_PROJECT, VERTEX_REGION, VERTEX_INDEX_ID to enable) ==="
  echo ""
fi

echo "Done: landing + mart built, tested, and synced (if configured)."
