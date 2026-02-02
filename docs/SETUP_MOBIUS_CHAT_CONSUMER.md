# Setup Instructions: Mobius Chat (Consumer)

**For:** Chat agent implementing the published RAG consumer side.  
**Contract:** See `CONTRACT_MOBIUS_CHAT_PUBLISHED_RAG.md` for the full specification.

---

## Overview

You will consume the BigQuery mart (`published_rag_embeddings`) produced by MOBIUS-DBT. The sync job (owned by MOBIUS-DBT) reads the mart and writes to:

1. **Your Postgres database:** Metadata table `published_rag_metadata` (no embeddings).
2. **Vertex AI Vector Search:** Embeddings (1536 dims) + filter metadata.

Your search flow: Query Vertex (embedding + filters) → get ids → fetch metadata from Postgres by id.

---

## Step 1: Create Postgres tables

**File:** `db/schema/002_published_rag_metadata.sql` (already created in Mobius-Chat repo)

**Apply the schema:**

```bash
# Connect to your Chat database
psql -h <your-chat-db-host> -U <your-user> -d mobius_chat -f db/schema/002_published_rag_metadata.sql
```

**Or if using Cloud SQL:**

```bash
# Start Cloud SQL proxy first
cloud-sql-proxy <your-instance-connection-name> --port 5432

# Then apply
psql -h 127.0.0.1 -U <your-user> -d mobius_chat -f db/schema/002_published_rag_metadata.sql
```

**Tables created:**

- `published_rag_metadata` (metadata only; id is PK and link to Vertex)
- `sync_runs` (audit table for sync runs)

**Indexes created:**

- Primary key on `id`
- Indexes on `document_id`, `updated_at`, `document_payer`, `document_state`, `document_program`, `document_authority_level`

---

## Step 2: Create Vertex AI Vector Search index

**In GCP Console:**

1. Go to: https://console.cloud.google.com/vertex-ai/matching-engine/indexes?project=mobiusos-new
2. Click **Create Index**
3. Configure:
   - **Name:** `mobius-chat-published-rag` (or your choice)
   - **Region:** `us-central1` (or your preferred region)
   - **Dimensions:** **1536** (critical: must match mart embeddings)
   - **Distance metric:** **Cosine** (or dot product; align with embedding model semantics)
   - **Index type:** **Streaming** (recommended for real-time upserts)
   - **Metadata filtering:** **Enable** (required for filtering by payer, state, program, authority_level)
4. Click **Create**
5. **Note the Index ID** (you'll need this for the sync job env vars)

**Deploy the index (create endpoint):**

1. After index is created, go to **Index Endpoints** → **Create Endpoint**
2. Configure:
   - **Name:** `mobius-chat-published-rag-endpoint`
   - **Region:** Same as index (`us-central1`)
3. Click **Create**
4. **Deploy your index** to this endpoint:
   - Select the endpoint → **Deploy Index**
   - Choose your index → Configure machine type (e.g. `n1-standard-2`)
   - Click **Deploy**
5. **Note the Endpoint ID** (you'll need this for `VERTEX_INDEX_ENDPOINT_ID`)

---

## Step 3: Provide connection details to MOBIUS-DBT team

The sync job (owned by MOBIUS-DBT) needs these env vars:

```bash
# Your Chat Postgres
CHAT_DATABASE_URL='postgresql://user:password@host:port/mobius_chat'

# Vertex AI (same project as MOBIUS-DBT uses for BigQuery)
VERTEX_PROJECT='mobiusos-new'
VERTEX_REGION='us-central1'
VERTEX_INDEX_ID='<your-index-id-from-step-2>'
VERTEX_INDEX_ENDPOINT_ID='<your-endpoint-id-from-step-2>'
```

**Share with MOBIUS-DBT team:**

- Postgres connection string (with credentials; use secrets manager in prod)
- Vertex index ID and endpoint ID

**Permissions:**

- MOBIUS-DBT service account needs:
  - **Postgres:** `INSERT`, `UPDATE` on `published_rag_metadata` and `sync_runs`
  - **Vertex:** `aiplatform.indexEndpoints.deploy`, `aiplatform.indexEndpoints.upsertDatapoints` (or equivalent for your index type)

---

## Step 4: Implement search logic (your code)

**Search flow:**

1. **Embed user query:** Use the same embedding model as the mart (e.g. `text-embedding-3-small`, 1536 dims). Call Vertex AI or OpenAI API.

2. **Query Vertex AI Vector Search:**
   ```python
   from google.cloud import aiplatform
   
   aiplatform.init(project=VERTEX_PROJECT, location=VERTEX_REGION)
   endpoint = aiplatform.MatchingEngineIndexEndpoint(index_endpoint_name=VERTEX_INDEX_ENDPOINT_ID)
   
   # Query with embedding + filters
   response = endpoint.find_neighbors(
       deployed_index_id=DEPLOYED_INDEX_ID,  # from your deployment
       queries=[query_embedding],  # 1536-dim array
       num_neighbors=10,
       filter=[
           {"namespace": "document_payer", "allow_list": ["Molina"]},
           {"namespace": "document_state", "allow_list": ["CA"]},
           # Add more filters as needed: document_program, document_authority_level, source_type
       ]
   )
   
   # Extract ids
   ids = [neighbor.id for neighbor in response[0]]
   ```

3. **Fetch metadata from Postgres:**
   ```python
   import psycopg2
   
   conn = psycopg2.connect(CHAT_DATABASE_URL)
   cur = conn.cursor()
   cur.execute(
       "SELECT * FROM published_rag_metadata WHERE id = ANY(%s)",
       (ids,)
   )
   rows = cur.fetchall()
   conn.close()
   ```

4. **Return context to LLM:**
   - Use `text` field for chunk/fact content
   - Use `document_*` fields for source attribution (filename, display_name, payer, state, etc.)
   - Use `source_type` to distinguish chunks (`'hierarchical'`) from facts (`'fact'`)

**Filtering:**

- **Required filter fields in Vertex:** `document_payer`, `document_state`, `document_program`, `document_authority_level`
- **Optional:** `source_type` (to filter chunks vs facts)
- Vertex restricts are set by the sync job; you just query with `filter` parameter

---

## Step 5: Monitor sync runs

**Check last sync status:**

```sql
-- In your Chat Postgres
SELECT * FROM sync_runs ORDER BY started_at DESC LIMIT 10;
```

**Or in BigQuery:**

```sql
-- In MOBIUS-DBT's BigQuery
SELECT * FROM `mobiusos-new.mobius_rag_dev.sync_runs` ORDER BY started_at DESC LIMIT 10;
```

**Columns:**

- `run_id`: Unique run identifier
- `started_at`, `finished_at`: Timestamps
- `mart_rows_read`, `postgres_rows_written`, `vector_rows_upserted`: Row counts
- `status`: `'success'` or `'failure'`
- `error_message`: Error detail if failed

---

## Step 6: Test the integration

**After the first sync run:**

1. **Check Postgres has data:**
   ```sql
   SELECT COUNT(*) FROM published_rag_metadata;
   SELECT * FROM published_rag_metadata LIMIT 5;
   ```

2. **Check Vertex has vectors:**
   - In GCP Console → Vertex AI → Vector Search → your index → **Datapoints**
   - Or query via API (see step 4)

3. **Test search:**
   - Embed a test query (e.g. "What does Molina cover?")
   - Query Vertex with filters (e.g. `document_payer='Molina'`)
   - Fetch metadata from Postgres by returned ids
   - Verify you get relevant chunks/facts

---

## Schema reference

### `published_rag_metadata` (Postgres)

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID (PK) | Link to Vertex AI Vector Search (same id stored there). |
| `document_id` | UUID | Document this row belongs to. |
| `source_type` | TEXT | `'hierarchical'` (chunk) or `'fact'`. |
| `source_id` | UUID | hierarchical_chunks.id or extracted_facts.id in RAG. |
| `model` | TEXT | Embedding model (e.g. `text-embedding-3-small`). |
| `created_at` | TIMESTAMPTZ | When this row was first created. |
| `text` | TEXT | The embedded text (chunk or fact). |
| `page_number` | INT | Page number in source document. |
| `paragraph_index` | INT | Paragraph index in chunk. |
| `section_path` | TEXT | Section hierarchy (e.g. `Chapter 1 > Section 1.1`). |
| `chapter_path` | TEXT | Chapter hierarchy. |
| `summary` | TEXT | Summary of the chunk/fact. |
| `document_filename` | TEXT | Original filename. |
| `document_display_name` | TEXT | Human-readable document name. |
| `document_authority_level` | TEXT | Authority level (e.g. `Federal`, `State`). |
| `document_effective_date` | TEXT | Effective date (ISO string). |
| `document_termination_date` | TEXT | Termination date (ISO string). |
| `document_payer` | TEXT | Payer (e.g. `Molina`, `UHC`). |
| `document_state` | TEXT | State (e.g. `CA`, `TX`). |
| `document_program` | TEXT | Program (e.g. `Medicaid`, `Medicare`). |
| `document_status` | TEXT | Document status. |
| `document_created_at` | TIMESTAMPTZ | When document was created. |
| `document_review_status` | TEXT | Review status (e.g. `approved`). |
| `document_reviewed_at` | TIMESTAMPTZ | Review timestamp. |
| `document_reviewed_by` | TEXT | Reviewer name/id. |
| `content_sha` | TEXT | SHA-256 hex of canonical content (for change detection). |
| `updated_at` | TIMESTAMPTZ | Last update time (publish time). |
| `source_verification_status` | TEXT | Verification status. |

### Vertex AI Vector Search datapoint

Each vector in Vertex has:

- **id** (string): Same as `published_rag_metadata.id` (UUID as string).
- **embedding** (array of 1536 floats): The vector.
- **Metadata (restricts):**
  - `document_payer` (string): For filtering (e.g. `Molina`).
  - `document_state` (string): For filtering (e.g. `CA`).
  - `document_program` (string): For filtering (e.g. `Medicaid`).
  - `document_authority_level` (string): For filtering (e.g. `Federal`).
  - `source_type` (string): `'hierarchical'` or `'fact'`.
  - `document_id` (string): Document UUID.
  - `source_id` (string): Source UUID.
  - `text` (string): Snippet of the embedded text (may be truncated).

---

## Contract

Full contract: `CONTRACT_MOBIUS_CHAT_PUBLISHED_RAG.md`

**Key points:**

- **Source of truth:** BigQuery mart `published_rag_embeddings` (owned by MOBIUS-DBT).
- **Sync job:** Owned by MOBIUS-DBT; runs after dbt run/test.
- **Your responsibility:** Provide Postgres connection + Vertex index; implement search logic.
- **Embedding dimensions:** 1536 (not 768; update your query embedding logic).
- **Grain:** One row per published chunk/fact (same as RAG's `rag_published_embeddings`).
- **Link:** `id` is the key; same in mart, Postgres, and Vertex.

---

## Questions?

Contact MOBIUS-DBT team or see `CONTRACT_CHAT_CONSUMER.md` for full details.
