#!/usr/bin/env bash
# Sync BigQuery mart to staging Chat Postgres (metadata only, skip Vertex since it's shared).
#
# Prerequisites:
#   1. Cloud SQL Proxy running: cloud-sql-proxy mobius-staging-mobius:us-central1:mobius-platform-staging-db --port=5433
#   2. .env has BQ_PROJECT and BQ_DATASET set, or they default to mobiusos-new/mobius_rag_dev
#   3. gcloud auth application-default login (for BigQuery access)
#
# Usage:
#   ./scripts/sync_to_staging.sh                    # prompts for password
#   ./scripts/sync_to_staging.sh "your_db_password" # pass password directly
#
# See docs/SYNC_TO_STAGING.md for full documentation.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "=== Sync BigQuery Mart → Staging Chat Postgres ==="
echo ""

# Load .env if present
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
    echo "Loaded .env"
fi

# Default BigQuery settings if not set
export BQ_PROJECT="${BQ_PROJECT:-mobiusos-new}"
export BQ_DATASET="${BQ_DATASET:-mobius_rag_dev}"

echo "BigQuery source: ${BQ_PROJECT}.${BQ_DATASET}.published_rag_embeddings"

# Get password - from arg, env, or prompt
if [[ -n "$1" ]]; then
    DB_PASS="$1"
    echo "Using password from command line argument"
elif [[ -n "$DEST_STAGING_CHAT_DATABASE_URL" ]]; then
    echo "Using DEST_STAGING_CHAT_DATABASE_URL from .env"
else
    echo ""
    echo "Get password with: gcloud secrets versions access latest --secret=db-password-mobius-chat --project=mobius-staging-mobius"
    echo ""
    read -sp "Enter staging DB password (mobius_app): " DB_PASS
    echo ""
fi

# Set the URL if we got a password
if [[ -n "$DB_PASS" ]]; then
    export DEST_STAGING_CHAT_DATABASE_URL="postgresql://mobius_app:${DB_PASS}@127.0.0.1:5433/mobius_chat"
fi

# Check Cloud SQL Proxy is running
echo ""
echo "Checking Cloud SQL Proxy on port 5433..."
if ! nc -z 127.0.0.1 5433 2>/dev/null; then
    echo ""
    echo "ERROR: Cloud SQL Proxy not running on port 5433"
    echo ""
    echo "Start it in another terminal:"
    echo "  cloud-sql-proxy mobius-staging-mobius:us-central1:mobius-platform-staging-db --port=5433"
    echo ""
    exit 1
fi
echo "✓ Cloud SQL Proxy is running"

# Run sync
echo ""
echo "Running sync (Postgres only, Vertex index is shared)..."
echo ""
python3 scripts/sync_mart_to_chat.py --dest staging --postgres-only

echo ""
echo "=== Done! ==="
echo ""
echo "Verify with:"
echo "  PGPASSWORD='...' psql -h 127.0.0.1 -p 5433 -U mobius_app -d mobius_chat -c 'SELECT COUNT(*) FROM published_rag_metadata;'"
