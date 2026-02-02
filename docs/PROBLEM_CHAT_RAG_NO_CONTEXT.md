# Problem: Mobius-Chat RAG returns no context (0 rows from Postgres)

## Issue

Mobius-Chat gets 10 neighbor ids from Vertex Vector Search, but Postgres `published_rag_metadata` returns **0 rows** for those ids. So RAG returns no context.

## Root cause

The Postgres database that Mobius-Chat uses (`CHAT_RAG_DATABASE_URL`) has the `published_rag_metadata` table but it is **empty**. The sync job (MOBIUS-DBT) that populates the Vertex index is either:

1. Not writing to this Postgres at all, or  
2. Writing to a different Postgres URL/database than Mobius-Chat uses.

## Contract Mobius-Chat expects

- **Same ids in Vertex and Postgres:** For every datapoint upserted to the Vertex index (the one used by Mobius-Chat), there must be exactly one row in Postgres `published_rag_metadata` with the same `id` (UUID).
- Mobius-Chat looks up metadata with:  
  `WHERE id::text = ANY(<vertex neighbor ids>)`.

## Postgres target

MOBIUS-DBT **must** write to the **same** Postgres that Mobius-Chat uses:

- **Database:** `mobius_chat`
- **Host:** Same as in Mobius-Chat’s `CHAT_RAG_DATABASE_URL` (e.g. `34.59.175.121`)
- **Table:** `published_rag_metadata`
- **Schema:** As in Mobius-Chat’s `db/schema/002_published_rag_metadata.sql` (e.g. `id` UUID PK, `document_id`, `source_type`, `source_id`, `text`, `page_number`, `document_display_name`, `document_filename`, etc.).

## Id consistency

The `id` (UUID) used when upserting each vector to Vertex **must** be the same `id` used for the corresponding row in `published_rag_metadata`. No extra transform or different id source for Postgres.

## What to fix in MOBIUS-DBT

1. **Ensure the sync that populates the Vertex index also writes (or upserts) rows into Postgres `published_rag_metadata`** for the **same** Postgres instance/database Mobius-Chat uses:  
   `CHAT_DATABASE_URL` (MOBIUS-DBT) = `CHAT_RAG_DATABASE_URL` (Mobius-Chat), e.g.  
   `postgresql://postgres:***@34.59.175.121:5432/mobius_chat`.

2. Use the **same id** per chunk/datapoint for both Vertex and Postgres.

3. Ensure required columns exist (at least those Mobius-Chat selects):  
   `id`, `document_id`, `source_type`, `text`, `page_number`, `document_display_name`, `document_filename`.

## References

- **Mobius-Chat schema:** `Mobius-Chat/db/schema/002_published_rag_metadata.sql`
- **Mobius-Chat lookup query:**  
  `SELECT id, document_id, source_type, text, page_number, document_display_name, document_filename FROM published_rag_metadata WHERE id::text = ANY(%s)`

## How to confirm it’s fixed

**1. In Postgres (same DB as CHAT_RAG_DATABASE_URL):**

```bash
psql -h 34.59.175.121 -U postgres -d mobius_chat -c "SELECT COUNT(*) FROM published_rag_metadata;"
```

**Expect:** `COUNT > 0` (e.g. hundreds or thousands after a full sync).

**2. In Mobius-Chat worker logs:**

Ask a non-patient question (e.g. “Describe Sunshine’s medical necessity criteria”) and check logs. You should see:

- Vertex find_neighbors returned 10 id(s)
- Postgres `published_rag_metadata` returned 10 row(s) for 10 id(s) (or similar; rows should match ids).
- No warning like “Some Vertex ids not found in Postgres”.

**3. In the chat UI:**

The answer should use real document snippets (e.g. “According to …”) and not say “The context does not contain information about …”.

---

Once MOBIUS-DBT writes to `mobius_chat.published_rag_metadata` with the same ids as in Vertex, this problem is fixed; the checks above confirm it.
