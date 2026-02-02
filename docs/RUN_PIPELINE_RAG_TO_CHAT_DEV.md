# Run Pipeline: RAG Prod → Chat Dev

One-time run to move a freshly published document (in RAG prod/GCP) through the pipeline and into Chat dev.

---

## Prerequisites

- RAG Postgres (prod) is reachable (Cloud SQL proxy if needed)
- BigQuery datasets `landing_rag` and `mobius_rag_dev` exist
- Chat dev Postgres has `published_rag_metadata` and `sync_runs` tables applied
- GCS bucket for Vertex batch index data (e.g. `mobiusos-new-vertex-index`)
- `gcloud auth application-default login` (or `GOOGLE_APPLICATION_CREDENTIALS` set)

## First-time: Create Vertex batch index

If no Vertex index exists yet:

1. **Run ingest + dbt** (sync skipped):

   ```bash
   export POSTGRES_HOST='34.59.175.121' POSTGRES_PASSWORD='MobiusOS123$'
   export BQ_PROJECT='mobiusos-new' BQ_DATASET='mobius_rag_dev'
   # Don't set CHAT_DATABASE_URL or VERTEX_INDEX_ID yet
   ./scripts/land_and_dbt_run.sh
   ```

2. **Create GCS bucket** (if needed):

   ```bash
   gsutil mb -l us-central1 gs://mobiusos-new-vertex-index
   ```

3. **Create batch index**:

   ```bash
   export BQ_PROJECT='mobiusos-new' BQ_DATASET='mobius_rag_dev'
   export GCS_BUCKET='mobiusos-new-vertex-index'
   export VERTEX_PROJECT='mobiusos-new' VERTEX_REGION='us-central1'
   python scripts/create_vertex_batch_index.py
   ```

4. **Deploy index** in GCP Console: Vertex AI → Vector Search → create endpoint → deploy index. Note the **index ID** and **endpoint ID**.

---

## Copy-paste commands

**1. From MOBIUS-DBT repo root, activate venv and set env vars:**

```bash
cd /Users/ananth/Mobius/mobius-dbt
source .venv/bin/activate

# RAG prod Postgres (where you just published)
export POSTGRES_HOST='34.59.175.121'   # or Cloud SQL proxy host if using proxy
export POSTGRES_PASSWORD='MobiusOS123$'
export POSTGRES_PORT='5432'
export POSTGRES_DB='mobius_rag'
export POSTGRES_USER='postgres'

# BigQuery (mart goes to dev)
export BQ_PROJECT='mobiusos-new'
export BQ_DATASET='mobius_rag_dev'

# Chat dev Postgres — MUST be the SAME DB as Mobius-Chat's CHAT_RAG_DATABASE_URL (same host, db mobius_chat). Otherwise Chat gets 0 rows for Vertex ids. See docs/PROBLEM_CHAT_RAG_NO_CONTEXT.md.
export CHAT_DATABASE_URL='postgresql://postgres:MobiusOS123$@34.59.175.121:5432/mobius_chat'

# Chat dev Vertex (batch index)
export VERTEX_PROJECT='mobiusos-new'
export VERTEX_REGION='us-central1'
export VERTEX_INDEX_ID='YOUR_CHAT_DEV_INDEX_ID'
export VERTEX_INDEX_MODE='batch'
export GCS_BUCKET='mobiusos-new-vertex-index'   # or your bucket for index data
export GCS_PREFIX='chat_rag_index'
```

**2. If no Vertex batch index exists yet, create it first:**

```bash
# One-time: create batch index (reads mart, exports to GCS, creates index)
python scripts/create_vertex_batch_index.py
# Then create endpoint + deploy in GCP Console, note INDEX_ID and ENDPOINT_ID
```

**3. Run the full pipeline:**

```bash
./scripts/land_and_dbt_run.sh
```

---

## What this does

1. **Ingest:** Reads `rag_published_embeddings` from RAG prod Postgres → writes to BigQuery `landing_rag.rag_published_embeddings`
2. **dbt run:** Builds mart `mobius_rag_dev.published_rag_embeddings` from landing
3. **dbt test:** Runs data tests on the mart
4. **Sync:** Reads mart → writes metadata to Chat dev Postgres (`published_rag_metadata`) and embeddings to Chat dev Vertex AI Vector Search

---

## If using Cloud SQL proxy for RAG prod

```bash
# Terminal 1: Start proxy
cloud-sql-proxy mobiusos-new:us-central1:YOUR_INSTANCE --port 5432

# Terminal 2: Run pipeline (use 127.0.0.1 as POSTGRES_HOST)
export POSTGRES_HOST='127.0.0.1'
export POSTGRES_PASSWORD='...'
# ... rest of env vars ...
./scripts/land_and_dbt_run.sh
```

---

## Streaming index (alternative to batch)

If you prefer a streaming index (real-time upserts), use:

```bash
export VERTEX_INDEX_ENDPOINT_ID='projects/.../indexEndpoints/...'
# Don't set VERTEX_INDEX_MODE or GCS_BUCKET
```

Streaming requires creating the index manually in Console (1536 dims, Cosine, Stream).

## If Chat dev is not set up yet (skip sync)

If you don't have Chat dev Postgres + Vertex configured, omit the Chat env vars. The pipeline will run ingest + dbt + test and **skip sync**:

```bash
export POSTGRES_HOST='...'
export POSTGRES_PASSWORD='...'
export BQ_PROJECT='mobiusos-new'
export BQ_DATASET='mobius_rag_dev'
# Don't set CHAT_DATABASE_URL or VERTEX_INDEX_ID

./scripts/land_and_dbt_run.sh
```

Then run sync later when Chat dev is ready:

```bash
export BQ_PROJECT='mobiusos-new'
export BQ_DATASET='mobius_rag_dev'
export CHAT_DATABASE_URL='...'
export VERTEX_PROJECT='mobiusos-new'
export VERTEX_REGION='us-central1'
export VERTEX_INDEX_ID='...'
export VERTEX_INDEX_ENDPOINT_ID='...'

python scripts/sync_mart_to_chat.py
```

---

## Verify

- **BigQuery:** `SELECT COUNT(*) FROM \`mobiusos-new.mobius_rag_dev.published_rag_embeddings\``
- **Chat Postgres:** `SELECT COUNT(*) FROM published_rag_metadata;`
- **Sync runs:** `SELECT * FROM sync_runs ORDER BY started_at DESC LIMIT 5;`
