# Lexicon & RAG Data Flow: Tables and Sync Paths

## Visual Schematic

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────┐
│                              LEXICON & RAG SYNC FLOW                                              │
└─────────────────────────────────────────────────────────────────────────────────────────────────┘

  mobius_qa                     mobius_rag                    BigQuery                    mobius_chat              Vertex AI
  (editing)                     (RAG source)                  (mart)                      (consumer)               (vectors)

┌──────────────────┐          ┌──────────────────┐          ┌──────────────────┐         ┌──────────────────┐    ┌─────────────┐
│ policy_lexicon_  │          │ policy_lexicon_  │          │                  │         │ policy_lexicon_  │    │             │
│   meta           │ sync_qa_ │   meta           │          │ published_rag_   │ sync_   │   meta           │    │ Vector      │
│ policy_lexicon_  │ lexicon  │ policy_lexicon_  │          │ embeddings       │ mart_   │ policy_lexicon_  │    │ Index       │
│   entries        │ ────────►│   entries        │          │ (mart)           │ to_     │   entries        │    │             │
│                  │   to_rag │ document_tags    │          │                  │ chat    │ document_tags    │    │             │
│ (QA team edits   │          │ (Path B worker   │ ingest   │ (from RAG        │ ───────►│ published_rag_   │───►│ Embeddings  │
│  lexicon here)   │          │  populates)      │ ◄─────── │  embeddings)     │         │   metadata       │    │             │
└──────────────────┘          │ documents       │          └──────────────────┘         │ sync_runs       │    └─────────────┘
                              │ rag_published_  │                   │                  └──────────────────┘
       ▲                      │   embeddings    │                   │
       │                      └────────┬───────┘                   │
       │                               │                           │
       │                    run_rag_   │         sync_rag_         │
       │                    lexicon_   │         lexicon_          │
       │                    migrations │         to_chat           │
       │                               │         (lexicon + tags)  │
       │ reload_clean_lexicon          │                           │
       │ (one-time seed)               │                           │
       └───────────────────────────────┴───────────────────────────┘
```

## Table Locations

| Table | mobius_qa | mobius_rag | mobius_chat | Created by |
|-------|:---------:|:----------:|:-----------:|------------|
| **policy_lexicon_meta** | ✓ | ✓ | ✓ (replicated) | RAG migrations; sync_qa→rag; sync_rag→chat |
| **policy_lexicon_entries** | ✓ (source of truth) | ✓ (published) | ✓ (replicated) | Same |
| **document_tags** | — | ✓ | ✓ (replicated) | Path B worker (RAG); sync_rag→chat |
| **policy_line_tags** | — | from policy_lines | ✓ (replicated) | sync_rag→chat (aggregated from policy_lines) |
| **published_rag_metadata** | — | — | ✓ | sync_mart_to_chat |
| **documents** | — | ✓ | — | RAG schema |
| **rag_published_embeddings** | — | ✓ | — | RAG publish API |
| **sync_runs** | — | — | ✓ | sync_mart_to_chat |

## Sync Scripts (mobius-dbt)

| Script | Source | Destination | What it copies |
|--------|--------|-------------|----------------|
| **run_rag_lexicon_migrations** | — | mobius_rag | Creates policy_lexicon_*, document_tags |
| **sync_qa_lexicon_to_rag** | mobius_qa | mobius_rag | policy_lexicon_meta, policy_lexicon_entries |
| **sync_rag_lexicon_to_chat** | mobius_rag | mobius_chat | policy_lexicon_meta, policy_lexicon_entries, document_tags, policy_line_tags (from policy_lines) |
| **ingest_rag_to_landing** | mobius_rag (rag_published_embeddings) | BigQuery landing | Embeddings + metadata |
| **sync_mart_to_chat** | BigQuery mart | mobius_chat + Vertex | published_rag_metadata, vectors |

## Pipeline Order (land_and_dbt_run.sh)

1. **ingest_rag_to_landing** — RAG Postgres → BigQuery landing
2. **dbt run** — Build mart (published_rag_embeddings)
3. **dbt test**
4. **sync_mart_to_chat** — Mart → Chat Postgres + Vertex
5. **sync_rag_lexicon_to_chat** — RAG → Chat (lexicon + document_tags)

## J/P/D Tagger Data Source

The retriever J/P/D tagger reads from **mobius_chat** when `RAG_DATABASE_URL` = `CHAT_RAG_DATABASE_URL`:

- `policy_lexicon_entries` → phrase map for tagging questions
- `document_tags` → resolve document_ids for BM25 corpus scoping
- `policy_line_tags` → line-level tag_match in reranker (per-chunk tags when chunk text matches a line)

---

## Critical: Use the same RAG as mobius-rag

**RAG source for lexicon sync** must be the same database that mobius-rag uses (`DATABASE_URL`).

| Component | Env var | Example (dev) |
|-----------|---------|---------------|
| mobius-rag | `DATABASE_URL` | `postgresql+asyncpg://...@34.135.72.145:5432/mobius_rag` |
| mobius-dbt sync | `RAG_DATABASE_URL` or `POSTGRES_*` | Same host as above |
| mobius-dbt sync | `CHAT_DATABASE_URL` | Same host, `mobius_chat` DB |

**If these point to different hosts**, sync will copy from the wrong (possibly empty) RAG. Ensure:
1. `sync_rag_lexicon_to_chat` uses `RAG_DATABASE_URL` = mobius-rag's `DATABASE_URL` (or `POSTGRES_*` that match)
2. Chat schema (`policy_lexicon_meta`, `policy_lexicon_entries`, `document_tags`) exists in the Chat DB before sync
