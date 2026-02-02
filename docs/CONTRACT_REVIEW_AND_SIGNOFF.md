# Contract Review and Sign-Off: RAG Published Output ↔ dbt Plan

**RAG contract:** Mobius RAG repo, `docs/CONTRACT_DBT_RAG.md` (Version 2026-02)  
**dbt plan reference:** MOBIUS-DBT plan – "Contract with Mobius-RAG: Input (What We Consume)"

---

## Contract Review: Alignment Summary

| Requirement (dbt plan) | RAG contract | Status |
|------------------------|--------------|--------|
| One or more output table(s) in PostgreSQL that we can read | Single table `rag_published_embeddings` in PostgreSQL | Met |
| Include vector embedding column (pgvector) | `embedding` column, type `vector(1536)`; BigQuery replication as ARRAY<FLOAT64>(1536) | Met |
| Only records ready for consumption | Explicit user action: Document Status → Publish/Republish; backend builds rows from chunk_embeddings + documents | Met |
| Contract schema (identity, content, document metadata, audit, change detection) | Section 3 of CONTRACT_DBT_RAG.md: identity/embedding, content/structure, document metadata, change detection; optional `source_verification_status` | Met |
| All required columns (text, page_number, paragraph_index, section_path, chapter_path, summary, document_*, document_review_*, content_sha, updated_at) | All present; sentinels (empty string, 0) and nullability as specified | Met |
| content_sha (64-char hex) and updated_at for change detection / idempotent sync | `content_sha` VARCHAR(64), `updated_at` TIMESTAMP; Section 4 describes use for change detection and idempotent sync | Met |
| Change handling explicit (append-only vs replace vs hybrid) | Section 4: full replace per document on Publish/Republish (DELETE rows for document_id, then INSERT); primary key `id` stable until source embedding changes | Met (edit-in-place per document) |
| Replica in BigQuery | Section 6: ingestion reads `rag_published_embeddings`, loads into warehouse (e.g. BigQuery landing), map embedding to ARRAY<FLOAT64>(1536) | Met |

**Optional addition in RAG:** `source_verification_status` (per-row verification for facts) – not in dbt plan; acceptable as optional and does not affect the contract.

**Conclusion:** The RAG contract satisfies the dbt plan's requirements and is suitable for consumption by the dbt/ingestion pipeline and for replication into BigQuery.

---

## DBT Agent Sign-Off

**Contract reviewed:** Mobius RAG, `docs/CONTRACT_DBT_RAG.md` (Version 2026-02).

The dbt/datalake side has reviewed the RAG contract and confirms:

- The single contract table **`rag_published_embeddings`** in PostgreSQL, with pgvector `embedding` column, is the only surface we will read and matches the planned "one or more output table(s) in PostgreSQL" with vector details.
- The schema in Section 3 matches the contract schema in the MOBIUS-DBT plan (identity, content/structure, document metadata, audit, change detection) and will be replicated as-is into BigQuery landing (with `embedding` mapped to ARRAY<FLOAT64>(1536)).
- Publish flow (explicit Publish/Republish, full replace per document) and change handling (content_sha, updated_at) support our ingestion and sync design (change detection, idempotent sync).

**DBT agent accepts this contract for consumption.** We will source from `rag_published_embeddings` (or its BigQuery replica) and produce marts per the MOBIUS-DBT plan.

**Signed off:** DBT / Data Lake agent  
**Date:** 2026-02-01

---

## RAG Agent Sign-Off

**Contract implemented:** Mobius RAG, `docs/CONTRACT_DBT_RAG.md` (Version 2026-02).

The RAG module has implemented the contract as specified:

- One contract table **`rag_published_embeddings`** in PostgreSQL, including the `embedding` column (pgvector).
- Rows written only on explicit user action (Publish/Republish) via `POST /documents/{document_id}/publish`.
- Schema and sentinels as in Section 3; change handling as in Section 4 (full replace per document_id, content_sha and updated_at present).

**RAG agent confirms this contract as the published output for the dbt agent and downstream consumers.**

**Signed off:** RAG agent  
**Date:** 2026-02-01
