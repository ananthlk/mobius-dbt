#!/usr/bin/env python3
"""
Run RAG migrations for policy_lexicon_meta, policy_lexicon_entries, document_tags.

Creates these tables in mobius_rag so sync_rag_lexicon_to_chat has a source.
Uses psycopg2 (no mobius-rag app dependency).

Env: RAG_DATABASE_URL or POSTGRES_HOST + POSTGRES_PASSWORD (builds URL)
"""
import asyncio
import os
import sys
from pathlib import Path

_project_root = Path(__file__).resolve().parent.parent
try:
    from dotenv import load_dotenv
    load_dotenv(_project_root / ".env")
except ImportError:
    pass

try:
    import psycopg2
except ImportError:
    print("Install psycopg2-binary: pip install psycopg2-binary", file=sys.stderr)
    sys.exit(1)


def _rag_url() -> str:
    url = os.environ.get("RAG_DATABASE_URL", "").strip()
    if url and "${" not in url:
        return url
    host = os.environ.get("POSTGRES_HOST", "").strip()
    password = os.environ.get("POSTGRES_PASSWORD", "").strip()
    if not host or not password:
        raise SystemExit("Set RAG_DATABASE_URL or POSTGRES_HOST + POSTGRES_PASSWORD")
    port = os.environ.get("POSTGRES_PORT", "5432")
    dbname = os.environ.get("POSTGRES_DB", "mobius_rag")
    user = os.environ.get("POSTGRES_USER", "postgres")
    return f"postgresql://{user}:{password}@{host}:{port}/{dbname}"


def run_migrations(url: str) -> None:
    conn = psycopg2.connect(url)
    conn.autocommit = True
    cur = conn.cursor()

    # 1. policy_lexicon_meta
    cur.execute("""
        CREATE TABLE IF NOT EXISTS policy_lexicon_meta (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            revision BIGINT NOT NULL DEFAULT 0,
            lexicon_version VARCHAR(50) NOT NULL DEFAULT 'v1',
            lexicon_meta JSONB,
            created_at TIMESTAMPTZ DEFAULT (NOW() AT TIME ZONE 'utc'),
            updated_at TIMESTAMPTZ DEFAULT (NOW() AT TIME ZONE 'utc')
        )
    """)
    cur.execute("SELECT 1 FROM policy_lexicon_meta LIMIT 1")
    if not cur.fetchone():
        cur.execute(
            "INSERT INTO policy_lexicon_meta (revision, lexicon_version, lexicon_meta) VALUES (0, 'v1', '{}')"
        )
    print("  policy_lexicon_meta OK")

    # 2. policy_lexicon_entries
    cur.execute("""
        CREATE TABLE IF NOT EXISTS policy_lexicon_entries (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            kind VARCHAR(10) NOT NULL,
            code VARCHAR(500) NOT NULL,
            parent_code VARCHAR(500),
            spec JSONB NOT NULL DEFAULT '{}',
            active BOOLEAN NOT NULL DEFAULT true,
            created_at TIMESTAMPTZ DEFAULT (NOW() AT TIME ZONE 'utc'),
            updated_at TIMESTAMPTZ DEFAULT (NOW() AT TIME ZONE 'utc'),
            UNIQUE(kind, code)
        )
    """)
    print("  policy_lexicon_entries OK")

    # 3. document_tags (check documents exists first; create without FK if not)
    cur.execute("""
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'document_tags'
    """)
    if cur.fetchone():
        print("  document_tags already exists")
    else:
        cur.execute("SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'documents'")
        if cur.fetchone():
            cur.execute("""
                CREATE TABLE document_tags (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    document_id UUID NOT NULL REFERENCES documents(id) UNIQUE,
                    p_tags JSONB,
                    d_tags JSONB,
                    j_tags JSONB,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
            """)
        else:
            cur.execute("""
                CREATE TABLE document_tags (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    document_id UUID NOT NULL UNIQUE,
                    p_tags JSONB,
                    d_tags JSONB,
                    j_tags JSONB,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
            """)
        cur.execute("CREATE INDEX IF NOT EXISTS ix_document_tags_document_id ON document_tags(document_id)")
        print("  document_tags OK")

    # 4. document_tags lexicon_revision, tagged_at
    for col, typ in [("lexicon_revision", "BIGINT"), ("tagged_at", "TIMESTAMPTZ")]:
        cur.execute(
            "SELECT 1 FROM information_schema.columns WHERE table_name = 'document_tags' AND column_name = %s",
            (col,),
        )
        if not cur.fetchone():
            cur.execute(f"ALTER TABLE document_tags ADD COLUMN {col} {typ}")
            print(f"  document_tags.{col} added")
    cur.close()
    conn.close()


def main() -> int:
    url = _rag_url()
    print(f"Running RAG lexicon migrations on {url.split('@')[-1]}...")
    try:
        run_migrations(url)
        print("Done.")
        return 0
    except Exception as e:
        print(f"Failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
