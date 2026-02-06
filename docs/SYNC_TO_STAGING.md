# Sync RAG Data to Staging

Sync the BigQuery mart (`published_rag_embeddings`) to **staging** Cloud SQL so the staging Chat app can use RAG.

**Note:** The Vertex AI index is shared between environments (prod/staging/dev). Only the Chat Postgres metadata needs to be synced per environment.

---

## Prerequisites

1. **BigQuery mart exists** — run the full pipeline at least once (`./scripts/land_and_dbt_run.sh`) to populate `mobiusos-new.mobius_rag_dev.published_rag_embeddings`

2. **Cloud SQL Proxy installed** — staging uses private Cloud SQL, accessed via proxy:
   ```bash
   # Install if needed
   brew install cloud-sql-proxy   # macOS
   # or download from https://cloud.google.com/sql/docs/mysql/sql-proxy
   ```

3. **GCP auth** — authenticate with gcloud:
   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```

4. **Staging DB password** — retrieve from Secret Manager:
   ```bash
   gcloud secrets versions access latest --secret=db-password-mobius-chat --project=mobius-staging-mobius
   ```

---

## Quick Start (One Command)

```bash
cd /path/to/mobius-dbt

# Terminal 1: Start Cloud SQL Proxy
cloud-sql-proxy mobius-staging-mobius:us-central1:mobius-platform-staging-db --port=5433

# Terminal 2: Run sync (replace YOUR_PASSWORD with actual password)
./scripts/sync_to_staging.sh "YOUR_PASSWORD"
```

---

## Step-by-Step

### 1. Start Cloud SQL Proxy

Staging Cloud SQL is private (no public IP). Use the proxy to connect:

```bash
cloud-sql-proxy mobius-staging-mobius:us-central1:mobius-platform-staging-db --port=5433
```

Keep this running in a separate terminal.

### 2. Get Staging DB Password

```bash
DB_PASS=$(gcloud secrets versions access latest --secret=db-password-mobius-chat --project=mobius-staging-mobius)
echo $DB_PASS  # copy this
```

### 3. Set Environment Variables

```bash
cd /path/to/mobius-dbt
source .venv/bin/activate  # if using virtualenv

# BigQuery source (mart)
export BQ_PROJECT='mobiusos-new'
export BQ_DATASET='mobius_rag_dev'

# Staging destination (via Cloud SQL Proxy)
export DEST_STAGING_CHAT_DATABASE_URL="postgresql://mobius_app:${DB_PASS}@127.0.0.1:5433/mobius_chat"
```

Or add to `.env`:
```bash
# In mobius-dbt/.env
BQ_PROJECT=mobiusos-new
BQ_DATASET=mobius_rag_dev
DEST_STAGING_CHAT_DATABASE_URL=postgresql://mobius_app:YOUR_PASSWORD@127.0.0.1:5433/mobius_chat
```

### 4. Run Sync

```bash
# Sync to staging (Postgres only, Vertex is shared)
python3 scripts/sync_mart_to_chat.py --dest staging --postgres-only
```

Or use the convenience script:
```bash
./scripts/sync_to_staging.sh "YOUR_PASSWORD"
```

---

## Verify

```bash
# Connect to staging and check row count
DB_PASS=$(gcloud secrets versions access latest --secret=db-password-mobius-chat --project=mobius-staging-mobius)
PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -p 5433 -U mobius_app -d mobius_chat \
  -c "SELECT COUNT(*) as rows, COUNT(DISTINCT document_id) as documents FROM published_rag_metadata;"
```

Expected output (should match BigQuery mart):
```
 rows  | documents 
-------+-----------
  8128 |         3
```

---

## Troubleshooting

### "Connection refused" on port 5433
Cloud SQL Proxy not running. Start it:
```bash
cloud-sql-proxy mobius-staging-mobius:us-central1:mobius-platform-staging-db --port=5433
```

### "Authentication failed"
Wrong password. Get fresh password:
```bash
gcloud secrets versions access latest --secret=db-password-mobius-chat --project=mobius-staging-mobius
```

### "No rows in mart"
BigQuery mart is empty. Run the full pipeline first:
```bash
./scripts/land_and_dbt_run.sh
```

### Sync succeeds but Chat still says "0 rows"
1. Check worker env vars include correct `CHAT_RAG_DATABASE_URL` pointing to staging Cloud SQL
2. Verify IDs match: Vertex returns IDs that must exist in Postgres

---

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  RAG Postgres   │ ──► │    BigQuery     │ ──► │  Chat Postgres  │
│  (prod/source)  │     │     (mart)      │     │   (staging)     │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
   ingest_rag_           dbt run              sync_mart_to_chat.py
   to_landing.py                                --dest staging
                                                --postgres-only
                                    
                        ┌─────────────────┐
                        │  Vertex Index   │  ◄── shared across envs
                        │   (mobiusos-new)│      (no sync needed)
                        └─────────────────┘
```

The Vertex AI Vector Search index is **shared** between environments. Only the Postgres metadata (`published_rag_metadata`) needs to be synced per environment.
