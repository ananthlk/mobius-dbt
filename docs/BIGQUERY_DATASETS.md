# BigQuery Dataset Organization (mobiusos-new)

Project: **mobiusos-new**

## Suggested layout

| Dataset          | Purpose |
|------------------|--------|
| **landing_rag**  | Ingestion from Mobius-RAG PostgreSQL. Table: `rag_published_embeddings` (replica of RAG's published table). |
| **mobius_rag**   | dbt marts for RAG/chat. Phase 1: table `published_rag_embeddings` (feed for chat server sync). |
| **mobius_rag_dev** | Same as mobius_rag for development (optional; use for `dbt run --target dev`). |

- **landing_rag** – raw/landing; populated by the ingestion job (RAG Postgres → BigQuery).
- **mobius_rag** – curated output; dbt builds here. Sync job reads from `mobius_rag.published_rag_embeddings` to load the chat server (vector DB + PostgreSQL).

## Create datasets

From the repo root (after `gcloud auth application-default login` or with `GOOGLE_APPLICATION_CREDENTIALS` set):

```bash
# Project
export BQ_PROJECT=mobiusos-new

# Create datasets (US multi-region; change location if needed)
bq mk --project_id=mobiusos-new --dataset --location=US mobiusos-new:landing_rag
bq mk --project_id=mobiusos-new --dataset --location=US mobiusos-new:mobius_rag
bq mk --project_id=mobiusos-new --dataset --location=US mobiusos-new:mobius_rag_dev
```

Or run the script: `./scripts/create_bq_datasets.sh`

## If `bq` hangs (stuck on `bq ls` or `create_bq_datasets.sh`)

1. **Test API reachability** (in another terminal):
   ```bash
   curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 https://bigquery.googleapis.com
   ```
   - `200` or `403` = reachable. Timeout = network/firewall/proxy blocking BigQuery.

2. **Enable BigQuery API** (if needed):  
   [APIs & Services → Enable BigQuery API](https://console.cloud.google.com/apis/library/bigquery.googleapis.com?project=mobiusos-new) for project **mobiusos-new**.

3. **Create datasets in the Console** (no `bq` CLI needed):
   - Open [BigQuery → Explorer](https://console.cloud.google.com/bigquery?project=mobiusos-new).
   - Select project **mobiusos-new** in the left panel.
   - Click the **⋮** next to the project name → **Create dataset**.
   - Create three datasets, each with **Data location: United States (US)**:
     - **landing_rag**
     - **mobius_rag**
     - **mobius_rag_dev**
   - Leave other options default, then **Create dataset**.

## dbt profile

- **Dev:** `BQ_PROJECT=mobiusos-new` and `BQ_DATASET=mobius_rag_dev` → dbt writes to `mobius_rag_dev.published_rag_embeddings`.
- **Prod:** `BQ_PROJECT=mobiusos-new` and `BQ_DATASET=mobius_rag` → dbt writes to `mobius_rag.published_rag_embeddings`.
- **Source:** dbt reads from `landing_rag.rag_published_embeddings` (set in `models/sources/_sources.yml`).
