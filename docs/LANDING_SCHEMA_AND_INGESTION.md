# BigQuery Landing Schema and Ingestion: RAG Published Embeddings

This document defines the BigQuery landing layer for the RAG published output and how to ingest from RAG's PostgreSQL into BigQuery.

**Ownership:** The RAG module writes only to **its own** destination (PostgreSQL + pgvector). It does not push to BigQuery. **We** (MOBIUS-DBT / data lake) own **landing**: we run the ingestion job that reads from RAG's PostgreSQL and writes to BigQuery `landing_rag.rag_published_embeddings`. dbt then builds the mart from that landing table.

**Managed in this repo:** Ingestion and mart build are both managed here. One pipeline runs **ingest → dbt run → dbt test**; you schedule that single job (e.g. Cloud Scheduler, Composer).

---

## Managed pipeline (ingest + dbt in this repo)

All transfer and transformation is managed by scripts in this repo. Run the pipeline locally or schedule it.

### One-shot: ingest then dbt

```bash
# From repo root, with venv activated and Postgres/BQ env set:
export POSTGRES_HOST=34.59.175.121   # or your Cloud SQL public IP
export POSTGRES_PASSWORD='your_postgres_password'
./scripts/land_and_dbt_run.sh
```

This runs in order:

1. **Ingest:** `scripts/ingest_rag_to_landing.py` — reads `rag_published_embeddings` from RAG PostgreSQL, maps pgvector → ARRAY<FLOAT64>, loads into BigQuery `landing_rag.rag_published_embeddings` (full replace).
2. **dbt run** — builds `mobius_rag_dev.published_rag_embeddings` (or prod dataset per profile) from the landing table.
3. **dbt test** — runs data tests on the mart.
4. **Sync (optional):** `scripts/sync_mart_to_chat.py` — reads the mart, writes metadata to Chat Postgres (`published_rag_metadata`) and embeddings to Vertex AI Vector Search. Runs if `CHAT_DATABASE_URL` and `VERTEX_INDEX_ID` are set; skipped otherwise.

### Env vars

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `POSTGRES_HOST` | Yes | — | RAG PostgreSQL host (e.g. Cloud SQL public IP). |
| `POSTGRES_PASSWORD` | Yes | — | postgres user password. |
| `POSTGRES_PORT` | No | `5432` | Postgres port. |
| `POSTGRES_DB` | No | `mobius_rag` | Database name. |
| `POSTGRES_USER` | No | `postgres` | User name. |
| `BQ_PROJECT` | No | `mobiusos-new` | BigQuery project. |
| `BQ_LANDING_DATASET` | No | `landing_rag` | BigQuery landing dataset (ingest writes here). |
| `BQ_DATASET` | No | `mobius_rag_dev` | BigQuery mart dataset (dbt output and sync source). |
| `BQ_TABLE` | No | `rag_published_embeddings` | Landing table name. |
| `CHAT_DATABASE_URL` | No (for sync) | — | Chat Postgres URL (e.g. `postgresql://user:pass@host:port/mobius_chat`). If set (with Vertex vars), step 4 (sync) runs. |
| `VERTEX_PROJECT` | No (for sync) | — | GCP project for Vertex AI. |
| `VERTEX_REGION` | No (for sync) | — | Vertex region (e.g. `us-central1`). |
| `VERTEX_INDEX_ID` | No (for sync) | — | Vertex AI Vector Search index id. |
| `VERTEX_INDEX_ENDPOINT_ID` | No (for sync) | — | Vertex index endpoint (if using deployed endpoint). |

BigQuery uses Application Default Credentials (`gcloud auth application-default login` or `GOOGLE_APPLICATION_CREDENTIALS`). dbt uses `profiles.yml` (same project/dataset as usual).

### Scheduling

Run the same pipeline on a schedule:

- **Cloud Scheduler + Cloud Run:** Build a small Docker image that runs `./scripts/land_and_dbt_run.sh` (with env from Secret Manager or env vars). Trigger the Cloud Run job on a cron schedule.
- **Cloud Composer (Airflow):** Create a DAG that runs a BashOperator or Python operator: set env, then `ingest_rag_to_landing.py`, then `dbt run`, then `dbt test`.
- **Cron on a VM:** `0 * * * * cd /path/to/MOBIUS-DBT && . .venv/bin/activate && export POSTGRES_HOST=... POSTGRES_PASSWORD=... && ./scripts/land_and_dbt_run.sh`.

---

## Source: RAG PostgreSQL

- **Table:** `rag_published_embeddings` (in Mobius-RAG's PostgreSQL; pgvector extension for `embedding` column).
- **Contract:** [Mobius RAG/docs/CONTRACT_DBT_RAG.md](https://github.com/.../Mobius-RAG/blob/main/docs/CONTRACT_DBT_RAG.md) (Version 2026-02), **Section 3** is the authoritative schema.
- **Access:** We have read access to RAG's PostgreSQL; we do not own or manage it.

---

## BigQuery Landing

- **Dataset:** `landing_rag` (or equivalent; configurable via ingestion job).
- **Table:** `rag_published_embeddings` (replica of the same schema as RAG's PostgreSQL table).
- **Schema:** Same columns and grain as CONTRACT_DBT_RAG.md Section 3, with one type mapping:
  - **PostgreSQL:** `embedding` → type `vector(1536)` (pgvector).
  - **BigQuery:** `embedding` → type **`ARRAY<FLOAT64>`** of length 1536 (or equivalent: e.g. 1536-element array). BigQuery does not have a native vector type; store as array of floats.

**Create the table if it does not exist:** Run the DDL in **`scripts/create_landing_table.sql`** in the BigQuery Console (Query editor, project `mobiusos-new`). That creates an empty `landing_rag.rag_published_embeddings` so `dbt run` can succeed; then run your ingestion to populate it.

### Column mapping (PostgreSQL → BigQuery)

| Column (same name) | PostgreSQL type | BigQuery type |
|--------------------|-----------------|---------------|
| id | UUID | STRING |
| document_id | UUID | STRING |
| source_type | VARCHAR(20) | STRING |
| source_id | UUID | STRING |
| embedding | vector(1536) | **ARRAY<FLOAT64>** (1536 elements) |
| model | VARCHAR(100) | STRING |
| created_at | TIMESTAMP | TIMESTAMP |
| text | TEXT | STRING |
| page_number | INTEGER | INT64 |
| paragraph_index | INTEGER | INT64 |
| section_path | VARCHAR(500) | STRING |
| chapter_path | VARCHAR(500) | STRING |
| summary | TEXT | STRING |
| document_filename | VARCHAR(255) | STRING |
| document_display_name | VARCHAR(255) | STRING |
| document_authority_level | VARCHAR(100) | STRING |
| document_effective_date | VARCHAR(20) | STRING |
| document_termination_date | VARCHAR(20) | STRING |
| document_payer | VARCHAR(100) | STRING |
| document_state | VARCHAR(2) | STRING |
| document_program | VARCHAR(100) | STRING |
| document_status | VARCHAR(20) | STRING |
| document_created_at | TIMESTAMP | TIMESTAMP |
| document_review_status | VARCHAR(20) | STRING |
| document_reviewed_at | TIMESTAMP | TIMESTAMP |
| document_reviewed_by | VARCHAR(255) | STRING |
| content_sha | VARCHAR(64) | STRING |
| updated_at | TIMESTAMP | TIMESTAMP |
| source_verification_status | VARCHAR(20) | STRING (optional) |

---

## Establishing the connection (PostgreSQL → BigQuery landing)

You can use **BigQuery pipelines** and related GCP services to land RAG data into BigQuery. Options:

| Option | Best for | Notes |
|--------|----------|--------|
| **BigQuery Data Transfer Service (PostgreSQL)** | Scheduled, managed transfers | Native [PostgreSQL connector](https://cloud.google.com/bigquery/docs/postgresql-transfer): connect to Postgres (Cloud SQL, on-prem, AWS, Azure), schedule recurring loads into a BigQuery dataset/table. Create a transfer config in Console → BigQuery → Data transfers, or via API. **Caveat:** `embedding` (pgvector) may need custom handling; check if the connector maps vector → ARRAY or if you need a custom job for that column. |
| **Datastream for BigQuery** | Near real-time CDC | [Datastream](https://cloud.google.com/datastream-for-bigquery): CDC from PostgreSQL to BigQuery (inserts/updates/deletes). Serverless, low latency. Create a stream: source = RAG PostgreSQL, destination = BigQuery; select table `rag_published_embeddings`. **Caveat:** pgvector → ARRAY<FLOAT64> may require a view or transformation layer; confirm supported types. |
| **Dataflow: PostgreSQL to BigQuery template** | Batch ETL | [Template](https://cloud.google.com/dataflow/docs/guides/templates/provided/postgresql-to-bigquery): JDBC read from Postgres, write to BigQuery. Run on a schedule (e.g. Cloud Scheduler + Dataflow). Good for full or incremental batch. You can extend the template to convert pgvector to array in the pipeline. |
| **Custom job (Composer / Airflow / script)** | Full control over pgvector mapping | Python (e.g. `psycopg2` + `google-cloud-bigquery`): read from RAG Postgres, convert `embedding` to list of floats, load into `landing_rag.rag_published_embeddings`. Run on Cloud Composer, Cloud Run, or a VM. Easiest way to guarantee pgvector → ARRAY<FLOAT64> exactly as in the contract. |

**Recommendation:** Use the **managed pipeline in this repo** (see “Managed pipeline” above): `scripts/ingest_rag_to_landing.py` + `dbt run` + `dbt test`, scheduled together. That handles pgvector → ARRAY<FLOAT64> and keeps ingestion and dbt in one place. The options below are alternatives if you prefer a different orchestrator.

---

## Ingestion Job (what the pipeline does)

- **Purpose:** Copy data from RAG's PostgreSQL table **`rag_published_embeddings`** into BigQuery **`landing_rag.rag_published_embeddings`**.
- **Frequency:** To be agreed (e.g. scheduled batch, CDC via Datastream, or on-demand).
- **Steps:**
  1. Connect to RAG's PostgreSQL (read-only).
  2. Read full table or incremental (e.g. by `updated_at`) from `rag_published_embeddings`.
  3. Map `embedding` from pgvector to a 1536-element array of floats (e.g. in Python: `list(embedding)` or equivalent).
  4. Write to BigQuery `landing_rag.rag_published_embeddings` (full replace, merge by `id`, or truncate-and-load per your strategy).
- **Ownership:** We (data lake / MOBIUS-DBT pipeline) own and run the ingestion job. It reads from RAG's PostgreSQL and writes to our BigQuery landing table. dbt sources from the **BigQuery landing** table only; it does not connect to PostgreSQL.

---

## dbt Usage

- **Source name:** `landing_rag` (or as defined in `models/sources/_sources.yml`).
- **Source table:** `rag_published_embeddings`.
- dbt models in `models/marts/chat_rag/` select from this source. See `models/sources/_sources.yml` for the exact source definition.
