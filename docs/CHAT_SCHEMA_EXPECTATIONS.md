# Mobius Chat: Expected Data Schema (Consumer of the Mart)

This document summarizes **Mobius Chat**’s expected database schema for RAG data, so the sync from BigQuery mart → Chat’s PostgreSQL (and optional vector DB) can be designed. Source: **Mobius-Chat** repo.

---

## Chat’s current schema (target)

Chat uses a **cloned RAG schema** in PostgreSQL: normalized tables **documents**, **chunks**, **chunk_embeddings** (and optional **facts**). Schema file: `Mobius-Chat/db/schema/001_rag_schema.sql`.

### 1. `documents`

| Column       | Type      | Notes |
|-------------|-----------|--------|
| id          | UUID PK   | |
| name        | TEXT NOT NULL | |
| source_type | TEXT      | Default `'document'` |
| created_at  | TIMESTAMPTZ | Default now() |
| metadata    | JSONB     | Default `{}` |

### 2. `chunks`

| Column       | Type      | Notes |
|-------------|-----------|--------|
| id          | UUID PK   | |
| document_id | UUID NOT NULL FK → documents(id) | |
| text        | TEXT NOT NULL | |
| page_number | INT       | |
| start_offset| INT       | |
| end_offset  | INT       | |
| created_at  | TIMESTAMPTZ | |
| metadata    | JSONB     | Default `{}` |

### 3. `chunk_embeddings`

| Column     | Type        | Notes |
|------------|-------------|--------|
| id         | UUID PK     | |
| chunk_id   | UUID NOT NULL FK → chunks(id), UNIQUE | |
| embedding  | **vector(768)** NOT NULL | pgvector; Chat README says Vertex text-embedding-005 (768 dims) |
| model_id   | TEXT        | |
| created_at | TIMESTAMPTZ | |

Indexes: `chunk_id`, and HNSW on `embedding` (cosine).

### 4. `facts` (optional)

| Column       | Type      | Notes |
|-------------|-----------|--------|
| id          | UUID PK   | |
| document_id | UUID FK   | |
| chunk_id    | UUID FK   | |
| fact_type   | TEXT      | |
| content     | TEXT NOT NULL | |
| created_at  | TIMESTAMPTZ | |
| metadata    | JSONB     | |

---

## How Chat uses the schema

- **Copy today:** `app/db/copy_from_rag.py` copies from a **source** RAG DB that already has the same shape (documents, chunks, chunk_embeddings). Source is expected to have columns: documents (id, name, source_type, created_at, metadata); chunks (id, document_id, text, page_number, start_offset, end_offset, created_at, metadata); chunk_embeddings (id, chunk_id, embedding, model_id, created_at).
- **Search:** `app/db/rag_db.py` runs: `chunk_embeddings` JOIN `chunks` JOIN `documents`, orders by `embedding <=> query_vector`, returns `text`, `document_id`, `document_name`, `page_number`, `source_type: "chunk"`.

So Chat expects **normalized** tables and **768-dimensional** embeddings for its current vector index.

---

## Our mart vs Chat’s schema

| Aspect | BigQuery mart (`published_rag_embeddings`) | Chat (PostgreSQL) |
|--------|-------------------------------------------|-------------------|
| Shape | **One flat row** per embedding (chunk or fact) with denormalized document_* and text, page_number, etc. | **Normalized:** documents, chunks, chunk_embeddings |
| Embedding dims | **1536** (contract: e.g. text-embedding-3-small) | **768** (Vertex text-embedding-005 in README) |
| Identity | `id` = chunk_embedding id; `source_id` = chunk or fact id; `document_id` | documents.id, chunks.id, chunk_embeddings.chunk_id → chunks.id |
| Facts | Rows with `source_type = 'fact'`; optional `source_verification_status` | Optional `facts` table; Chat search today is chunk-only |

---

## Mapping: mart row → Chat tables

A **sync job** (BigQuery mart → Chat PostgreSQL) would need to:

1. **Documents**  
   From mart: `document_id`, `document_display_name` or `document_filename` (→ `name`), `document_created_at` (→ `created_at`). Insert/upsert by `document_id`. `metadata` can be built from other document_* columns if Chat needs them.

2. **Chunks**  
   For rows with `source_type = 'hierarchical'`: use `source_id` as chunk `id`, `document_id`, `text`, `page_number`. `paragraph_index` could go into `metadata`. Mart does not have `start_offset`/`end_offset`; use NULL or 0 if Chat allows.

3. **Chunk embeddings**  
   For `source_type = 'hierarchical'`: use mart `id` as chunk_embedding `id`, `source_id` as `chunk_id`, `embedding`, `model` → `model_id`, `created_at`.  
   **Dimension mismatch:** Mart has **1536**-dim vectors; Chat schema is **vector(768)**. Options: (a) Chat migrates to 1536 and same model as RAG, or (b) sync job downsamples/remaps (not ideal), or (c) Chat supports a second table or configurable dims for 1536.

4. **Facts**  
   For rows with `source_type = 'fact'`: either (a) insert into Chat’s `facts` table (content = mart `text`, link document_id/chunk_id if applicable), or (b) represent as synthetic “chunks” so existing search works, or (c) extend Chat to search facts separately.

---

## Recommendation for Chat

- **Schema:** Document that the **source of truth for published RAG data** is the BigQuery mart (`published_rag_embeddings`). Sync job reads from the mart and writes to Chat’s PostgreSQL (and optional vector DB) in the shape above.
- **Embedding dimensions:** Align on **1536** (RAG contract) so the mart and Chat use the same model; Chat would change `vector(768)` to `vector(1536)` and use the same embedding provider as RAG, or document 768 as legacy and support 1536 for new data.
- **Facts:** Decide whether Chat will consume `source_type = 'fact'` rows (e.g. via `facts` table or a unified search over chunks + facts) and document the mapping.

Once Chat confirms the desired target schema (and any change to 768 → 1536), the sync job from BigQuery mart → Chat can be specified in this repo or in Mobius-Chat.
