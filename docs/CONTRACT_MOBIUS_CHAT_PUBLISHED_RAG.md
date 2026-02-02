# Contract: MOBIUS-DBT → Mobius Chat (Consumer)

**Version:** 2026-02  
**For:** Mobius Chat agent and downstream consumers of the BigQuery mart

---

## 1. Parties and purpose

- **Producer:** MOBIUS-DBT. Produces a BigQuery mart (`published_rag_embeddings`) from RAG's published data. The mart is the **source of truth** for published RAG embeddings (chunks and facts) with full document metadata.
- **Consumer:** Mobius Chat. Consumes the mart by syncing it into (1) **PostgreSQL** (metadata only + link to vector DB) and (2) **Vertex AI Vector Search** (embeddings + facts + filter metadata).

The consumer does **not** read the BigQuery mart directly at query time. Instead, the **sync job** (owned by MOBIUS-DBT) reads the mart and writes to Chat's Postgres and Vertex. Chat then queries Vertex for similarity search and fetches full metadata from Postgres by id.

---

## 2. Source of truth: BigQuery mart

- **Table:** `<project>.<dataset>.published_rag_embeddings` (e.g. `mobiusos-new.mobius_rag_dev.published_rag_embeddings` for dev, `mobius_rag.published_rag_embeddings` for prod).
- **Schema:** See MOBIUS-DBT repo [models/marts/chat_rag/schema.yml](../models/marts/chat_rag/schema.yml) (dbt contract with column data types and constraints).
- **Grain:** One row per published embedding (chunk or fact). Same grain as RAG's `rag_published_embeddings` (see `docs/CONTRACT_DBT_RAG.md`).
- **Key columns:**
  - `id` (STRING, UUID): Primary key; stable across republishes for the same chunk/fact.
  - `document_id` (STRING, UUID): Document this row belongs to.
  - `source_type` (STRING): `'hierarchical'` (chunk) or `'fact'`.
  - `source_id` (STRING, UUID): hierarchical_chunks.id or extracted_facts.id.
  - `embedding` (ARRAY<FLOAT64>, 1536 elements): The embedding vector.
  - `text` (STRING): The text that was embedded (chunk or fact text).
  - `document_payer`, `document_state`, `document_program`, `document_authority_level` (STRING): Filter fields for Chat queries.
  - `content_sha` (STRING): SHA-256 hex of canonical content; for change detection.
  - `updated_at` (TIMESTAMP): Last update time (publish time).
  - Plus: `model`, `created_at`, `page_number`, `paragraph_index`, `section_path`, `chapter_path`, `summary`, all other `document_*` fields, `source_verification_status`.

---

## 3. Chat PostgreSQL (metadata store)

### Table: `published_rag_metadata`

- **Grain:** One row per mart row (one row per published chunk/fact).
- **Purpose:** Metadata for filtering, joins, and "after vector search, fetch full row by id."
- **Columns:** All mart columns **except** `embedding`:
  - `id` (UUID, PK): **Link to Vertex AI Vector Search** (same id stored there).
  - `document_id` (UUID, NOT NULL)
  - `source_type` (TEXT, NOT NULL): `'hierarchical'` or `'fact'`.
  - `source_id` (UUID, NOT NULL)
  - `model` (TEXT)
  - `created_at` (TIMESTAMPTZ, NOT NULL)
  - `text` (TEXT): The embedded text.
  - `page_number` (INT)
  - `paragraph_index` (INT)
  - `section_path` (TEXT)
  - `chapter_path` (TEXT)
  - `summary` (TEXT)
  - `document_filename` (TEXT)
  - `document_display_name` (TEXT)
  - `document_authority_level` (TEXT)
  - `document_effective_date` (TEXT)
  - `document_termination_date` (TEXT)
  - `document_payer` (TEXT)
  - `document_state` (TEXT)
  - `document_program` (TEXT)
  - `document_status` (TEXT)
  - `document_created_at` (TIMESTAMPTZ)
  - `document_review_status` (TEXT)
  - `document_reviewed_at` (TIMESTAMPTZ)
  - `document_reviewed_by` (TEXT)
  - `content_sha` (TEXT, NOT NULL): SHA-256 hex.
  - `updated_at` (TIMESTAMPTZ, NOT NULL): Last update time.
  - `source_verification_status` (TEXT)
- **Indexes:** At least `id` (PK); consider `document_id`, `updated_at`, `document_payer`, `document_state` for filtering.
- **Semantics:** Full replace per sync run (truncate then insert, or upsert by `id`). Each sync reflects the current state of the mart.

---

## 4. Vertex AI Vector Search (embedding store)

### Index configuration

- **Dimensions:** 1536 (match RAG contract and mart).
- **Distance metric:** Cosine (or dot product; align with RAG's embedding model semantics).
- **Index type:** Streaming or batch; recommend streaming for incremental updates.

### Datapoint schema (per vector)

Each datapoint in the Vertex index MUST have:

- **id** (string): Same as mart `id` (UUID as string). This is the **link** to Postgres `published_rag_metadata.id`.
- **embedding** (array of 1536 floats): The vector.
- **Metadata (restricts / filtering):**
  - **Required for filtering:** `document_payer` (string), `document_state` (string), `document_program` (string), `document_authority_level` (string). Chat queries can filter by these at search time (e.g. "payer=Molina AND state=CA").
  - **Recommended for display/context:** `document_id` (string), `source_type` (string: 'hierarchical' or 'fact'), `source_id` (string), `text` (string, truncated to e.g. 500 chars if needed for index limits).
  - **Optional:** `content_sha` (string), `updated_at` (ISO timestamp string) for lifecycle/filtering.

**Chunks and facts:** One index with `source_type` in metadata. Chat queries can filter by `source_type` if needed (e.g. "only chunks" or "only facts").

**Semantics:** Upsert by `id`. If a mart row changes (republish), the sync job upserts with the same `id`, replacing the old vector and metadata.

---

## 5. Link between Postgres and Vertex

- **Key:** `id` (UUID, stored as string in Vertex).
- **Flow:**
  1. **Sync:** For each mart row, write metadata to Postgres `published_rag_metadata` (keyed by `id`) and upsert vector + metadata to Vertex (keyed by `id`).
  2. **Search (Chat):** Query Vertex with embedding + filters (e.g. `document_payer='Molina'`) → get list of `id`s → fetch full metadata from Postgres `published_rag_metadata WHERE id IN (...)`.
- **Guarantee:** Every `id` in Postgres has a corresponding vector in Vertex (and vice versa, modulo sync lag).

---

## 6. Embedding dimensions and model

- **Dimensions:** 1536 (align with RAG contract; Chat drops 768-only assumption).
- **Model:** Typically `text-embedding-3-small` or equivalent (from mart `model` column). Chat's query embedding MUST use the same model/dims as the indexed vectors.

---

## 7. Sync job (owned by MOBIUS-DBT)

The sync job reads the BigQuery mart and writes to Chat's Postgres and Vertex. It runs as part of the MOBIUS-DBT pipeline (after `dbt run` and `dbt test`).

### Behavior

1. **Read** BigQuery mart: `SELECT * FROM <BQ_PROJECT>.<BQ_DATASET>.published_rag_embeddings`.
2. **Write metadata to Chat Postgres:** For each row, `INSERT ... ON CONFLICT (id) DO UPDATE` into `published_rag_metadata` (all columns except `embedding`).
3. **Upsert vectors to Vertex AI Vector Search:** For each row, upsert datapoint: `id`, `embedding`, and metadata (filter fields: `document_payer`, `document_state`, `document_program`, `document_authority_level`; plus `document_id`, `source_type`, `source_id`, `text` snippet).
4. **Write run output** (see section 8).

### Env vars

| Variable | Required | Description |
|----------|----------|-------------|
| `BQ_PROJECT` | Yes | BigQuery project (e.g. `mobiusos-new`). |
| `BQ_DATASET` | Yes | Mart dataset (e.g. `mobius_rag_dev` or `mobius_rag`). |
| `CHAT_DATABASE_URL` | Yes | Chat Postgres connection. **Must be the same database** as Mobius-Chat’s `CHAT_RAG_DATABASE_URL` (same host, database `mobius_chat`), or Chat will get 0 rows for Vertex ids. E.g. `postgresql://postgres:***@34.59.175.121:5432/mobius_chat`. |
| `VERTEX_PROJECT` | Yes | GCP project for Vertex AI. |
| `VERTEX_REGION` | Yes | Vertex region (e.g. `us-central1`). |
| `VERTEX_INDEX_ID` | Yes | Vertex AI Vector Search index id (or endpoint name). |
| `VERTEX_INDEX_ENDPOINT_ID` | Optional | If using deployed index endpoint. |

BigQuery and Vertex use Application Default Credentials (`gcloud auth application-default login` or `GOOGLE_APPLICATION_CREDENTIALS`).

---

## 8. Run output (audit and observability)

Each sync run MUST produce a durable record.

### Schema: `sync_runs`

| Column | Type | Description |
|--------|------|-------------|
| `run_id` | UUID/STRING | Unique run identifier. |
| `started_at` | TIMESTAMP | When sync started. |
| `finished_at` | TIMESTAMP | When sync finished (null if still running or crashed). |
| `mart_rows_read` | INT64 | Number of rows read from BigQuery mart. |
| `postgres_rows_written` | INT64 | Number of rows written/upserted to Chat Postgres. |
| `vector_rows_upserted` | INT64 | Number of vectors upserted to Vertex. |
| `status` | STRING | `'success'`, `'failure'`, or `'running'`. |
| `error_message` | STRING | Error detail if status = failure; null otherwise. |

### Where to persist

- **BigQuery:** Table `<BQ_PROJECT>.<BQ_DATASET>.sync_runs` (e.g. `mobiusos-new.mobius_rag_dev.sync_runs`). Same project/dataset as the mart.
- **Chat Postgres:** Table `sync_runs` (same schema, types adjusted: TIMESTAMPTZ, etc.). Created by Chat schema migration.

**Requirement:** Sync job MUST write to **at least** BigQuery `sync_runs`. Writing to Chat Postgres `sync_runs` is **recommended** for Chat's visibility.

### Implementation

The sync script (`scripts/sync_mart_to_chat.py`):

1. At start: generate `run_id`, insert `(run_id, started_at, status='running')` into BigQuery `sync_runs` (and optionally Chat `sync_runs`).
2. At end (success or failure): update the row with `finished_at`, counts, `status='success'` or `'failure'`, and `error_message` if failed. Or: insert with all fields at end if simpler (single insert after completion).

---

## 9. Chat repo changes (Mobius-Chat)

### New schema file: `db/schema/002_published_rag_metadata.sql`

**Create:**

- **Table `published_rag_metadata`** (all mart columns except `embedding`; see section 3).
- **Table `sync_runs`** (see section 8; optional if Chat wants to track sync in its own DB).

**Apply:** Run this migration in Chat's database (e.g. `psql -f db/schema/002_published_rag_metadata.sql` or via Chat's init/migration flow).

### Search path (follow-up)

Chat app will need a new search implementation:

1. Embed user query (same model/dims as mart: 1536).
2. Query Vertex AI Vector Search with embedding + filters (e.g. `document_payer='Molina'`, `document_state='CA'`) → get list of `id`s.
3. Fetch full metadata from Postgres: `SELECT * FROM published_rag_metadata WHERE id IN (...)`.
4. Return context to LLM.

Existing search (`app/db/rag_db.py`: pgvector in Postgres) can remain for backward compatibility or be deprecated. Contract does not mandate Chat's internal search logic; only the schema.

---

## 10. Summary for Chat agent

- **Consume:** BigQuery mart `published_rag_embeddings` (via sync job; you do not query BigQuery directly).
- **Store:**
  - Postgres: `published_rag_metadata` (metadata + link; no embeddings).
  - Vertex AI Vector Search: embeddings + filter metadata (payer, state, program, authority_level) + context metadata (document_id, source_type, text).
- **Search:** Query Vertex (embedding + filters) → get ids → fetch Postgres by id.
- **Embedding model:** 1536-dim (align with RAG); use the same model for query embeddings.
- **Run output:** Check `sync_runs` (Postgres or BigQuery) for last sync timestamp and status.

---

## 11. Sign-off

- **Producer (MOBIUS-DBT):** [Sign-off placeholder]
- **Consumer (Mobius Chat):** [Sign-off placeholder]

After both parties agree, update this section with names/dates.
