#!/usr/bin/env python3
"""
Publish QA lexicon to RAG DB.

Copies all active entries from mobius_qa.policy_lexicon_entries → mobius_rag.policy_lexicon_entries.
Also syncs the revision number in policy_lexicon_meta.

This is the official "publish" step: QA is the editing workspace, RAG gets the approved snapshot.

Usage:
  # Preview what would change
  QA_DATABASE_URL='postgresql://...' RAG_DATABASE_URL='postgresql://...' python3 sync_qa_lexicon_to_rag.py --dry-run

  # Actually publish
  QA_DATABASE_URL='postgresql://...' RAG_DATABASE_URL='postgresql://...' python3 sync_qa_lexicon_to_rag.py

Can also be called programmatically:
  from sync_qa_lexicon_to_rag import publish_lexicon
  result = publish_lexicon(qa_url, rag_url, dry_run=False)
"""

import json
import os
import sys
import uuid


def publish_lexicon(qa_url: str, rag_url: str, dry_run: bool = False) -> dict:
    """Copy QA lexicon → RAG DB. Returns summary dict."""
    import psycopg2
    import psycopg2.extras

    # 1. Read from QA (source of truth)
    qa = psycopg2.connect(qa_url)
    qa.autocommit = True
    qcur = qa.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    qcur.execute("SELECT COALESCE(revision,0)::bigint AS revision FROM policy_lexicon_meta ORDER BY updated_at DESC NULLS LAST LIMIT 1")
    qa_meta = qcur.fetchone()
    qa_revision = int(qa_meta["revision"]) if qa_meta else 0

    qcur.execute("SELECT kind, code, parent_code, spec, active FROM policy_lexicon_entries WHERE active = true ORDER BY kind, code")
    qa_entries = [dict(r) for r in qcur.fetchall()]
    qcur.close()
    qa.close()

    # 2. Read current RAG state
    rag = psycopg2.connect(rag_url)
    rag.autocommit = True
    rcur = rag.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    rcur.execute("SELECT COALESCE(revision,0)::bigint AS revision FROM policy_lexicon_meta ORDER BY updated_at DESC NULLS LAST LIMIT 1")
    rag_meta = rcur.fetchone()
    rag_revision = int(rag_meta["revision"]) if rag_meta else 0

    rcur.execute("SELECT count(*) AS cnt FROM policy_lexicon_entries")
    rag_count = int(rcur.fetchone()["cnt"])

    summary = {
        "qa_revision": qa_revision,
        "rag_revision_before": rag_revision,
        "qa_entries": len(qa_entries),
        "rag_entries_before": rag_count,
    }

    if dry_run:
        by_kind = {}
        for e in qa_entries:
            k = e["kind"]
            by_kind[k] = by_kind.get(k, 0) + 1
        summary["dry_run"] = True
        summary["would_publish"] = by_kind
        rcur.close()
        rag.close()
        return summary

    # 3. Truncate RAG lexicon and re-insert from QA
    rcur.execute("TRUNCATE TABLE policy_lexicon_entries")

    for e in qa_entries:
        spec_json = json.dumps(e["spec"]) if isinstance(e["spec"], dict) else "{}"
        rcur.execute(
            """
            INSERT INTO policy_lexicon_entries (id, kind, code, parent_code, spec, active, created_at, updated_at)
            VALUES (%s, %s, %s, %s, %s::jsonb, %s, NOW(), NOW())
            """,
            (str(uuid.uuid4()), e["kind"], e["code"], e.get("parent_code"), spec_json, True),
        )

    # 4. Sync revision in RAG meta
    rcur.execute("SELECT id FROM policy_lexicon_meta ORDER BY updated_at DESC NULLS LAST LIMIT 1")
    meta_row = rcur.fetchone()
    if meta_row and meta_row.get("id"):
        rcur.execute(
            "UPDATE policy_lexicon_meta SET revision = %s, updated_at = NOW() WHERE id = %s",
            (qa_revision, meta_row["id"]),
        )
    else:
        rcur.execute(
            "INSERT INTO policy_lexicon_meta (id, lexicon_version, lexicon_meta, revision, created_at, updated_at) VALUES (%s, 'v1', '{}'::jsonb, %s, NOW(), NOW())",
            (str(uuid.uuid4()), qa_revision),
        )

    rcur.close()
    rag.close()

    summary["rag_revision_after"] = qa_revision
    summary["rag_entries_after"] = len(qa_entries)
    summary["published"] = True
    return summary


def main():
    dry_run = "--dry-run" in sys.argv
    qa_url = os.environ.get("QA_DATABASE_URL")
    rag_url = os.environ.get("RAG_DATABASE_URL")
    if not qa_url or not rag_url:
        print("ERROR: QA_DATABASE_URL and RAG_DATABASE_URL are required", file=sys.stderr)
        sys.exit(1)

    result = publish_lexicon(qa_url, rag_url, dry_run=dry_run)

    if dry_run:
        print(f"[DRY RUN] QA revision: {result['qa_revision']}, RAG revision: {result['rag_revision_before']}")
        print(f"  QA has {result['qa_entries']} active entries")
        print(f"  RAG has {result['rag_entries_before']} entries (would be replaced)")
        print(f"  Would publish: {result.get('would_publish', {})}")
    else:
        print(f"Published QA lexicon → RAG DB")
        print(f"  QA revision: {result['qa_revision']}")
        print(f"  RAG: {result['rag_entries_before']} entries → {result['rag_entries_after']} entries")
        print(f"  RAG revision: {result['rag_revision_before']} → {result['rag_revision_after']}")


if __name__ == "__main__":
    main()
