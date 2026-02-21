#!/usr/bin/env python3
"""
Sync policy_lexicon_meta, policy_lexicon_entries, document_tags, policy_line_tags from RAG Postgres to Chat Postgres.

Enables J/P/D tagger in mobius-retriever to use CHAT_RAG_DATABASE_URL (same DB as published_rag_metadata)
instead of a separate RAG_DATABASE_URL.

Run after sync_mart_to_chat.py as part of the publish flow. Safe to run standalone.

Env (required when run standalone):
  RAG_DATABASE_URL  (RAG Postgres: mobius_rag with policy_lexicon_*, document_tags, policy_lines)
  CHAT_DATABASE_URL (Chat Postgres: same as CHAT_RAG_DATABASE_URL for mobius-chat)

Env (optional - used when RAG_DATABASE_URL not set):
  DATABASE_URL      (mobius-rag URL; converted from asyncpg to psycopg2)
  POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB=mobius_rag, POSTGRES_USER, POSTGRES_PASSWORD

Usage:
  python scripts/sync_rag_lexicon_to_chat.py
  # or as step 5 of land_and_dbt_run.sh (after sync_mart_to_chat)
"""

import json
import os
import sys
import uuid
from pathlib import Path

_project_root = Path(__file__).resolve().parent.parent
try:
    from dotenv import load_dotenv
    load_dotenv(_project_root / ".env")
except ImportError:
    pass

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    print("Install psycopg2-binary: pip install psycopg2-binary", file=sys.stderr)
    sys.exit(1)


def _connect_db(url: str):
    """Connect using URL; parse into components to handle special chars in password."""
    import urllib.parse

    try:
        from sqlalchemy.engine import make_url
        parsed = make_url(url)
        return psycopg2.connect(
            host=parsed.host or "localhost",
            port=parsed.port or 5432,
            dbname=(parsed.database or "postgres").lstrip("/"),
            user=parsed.username or "postgres",
            password=parsed.password or "",
            connect_timeout=10,
        )
    except ImportError:
        pass

    parsed = urllib.parse.urlparse(url)
    netloc = parsed.netloc
    path = (parsed.path or "/").lstrip("/") or "postgres"
    userinfo, _, hostport = netloc.rpartition("@")
    if not hostport:
        return psycopg2.connect(url)
    username, _, password = userinfo.partition(":")
    password = urllib.parse.unquote_to_bytes(password).decode("utf-8", "replace")
    host, _, port_str = hostport.rpartition(":")
    port = int(port_str) if port_str.isdigit() else 5432
    return psycopg2.connect(
        host=host or "localhost",
        port=port,
        dbname=path,
        user=urllib.parse.unquote(username) if username else "postgres",
        password=password,
        connect_timeout=10,
    )


def _dbname_from_url(url: str) -> str | None:
    """Extract database name from postgres URL."""
    try:
        from urllib.parse import urlparse
        p = urlparse(url)
        path = (p.path or "").strip("/").split("?")[0]
        return path or None
    except Exception:
        return None


def _rag_database_url() -> str | None:
    """Build RAG database URL from env. Source must be mobius_rag (document_tags, policy_lines)."""
    chat_url = (os.environ.get("CHAT_DATABASE_URL") or os.environ.get("CHAT_RAG_DATABASE_URL") or "").strip()
    chat_db = _dbname_from_url(chat_url) if chat_url else None

    def _pg2(url: str) -> str:
        return url.replace("postgresql+asyncpg://", "postgresql://", 1)

    # RAG_DATABASE_URL: use if points to mobius_rag or different DB from Chat
    url = os.environ.get("RAG_DATABASE_URL", "").strip()
    if url and "${" not in url:
        db = _dbname_from_url(url)
        if db and ("mobius_rag" in db or db != chat_db):
            return url

    # DATABASE_URL (mobius-rag) — document_tags, policy_lines live here
    url = os.environ.get("DATABASE_URL", "").strip()
    if url and "${" not in url:
        db = _dbname_from_url(url)
        if db and "mobius_rag" in db:
            return _pg2(url)

    # RAG_DATABASE_URL as fallback
    url = os.environ.get("RAG_DATABASE_URL", "").strip()
    if url and "${" not in url:
        return url

    # DATABASE_URL (any)
    url = os.environ.get("DATABASE_URL", "").strip()
    if url and "${" not in url:
        return _pg2(url)

    # Build from POSTGRES_*
    host = os.environ.get("POSTGRES_HOST", "").strip()
    password = os.environ.get("POSTGRES_PASSWORD", "").strip()
    if not host or not password:
        return None
    port = os.environ.get("POSTGRES_PORT", "5432")
    dbname = os.environ.get("POSTGRES_DB", "mobius_rag")
    user = os.environ.get("POSTGRES_USER", "postgres")
    return f"postgresql://{user}:{password}@{host}:{port}/{dbname}"


def _normalize_text_for_match(t: str) -> str:
    """Match mobius-retriever jpd_tagger._normalize_text_for_match."""
    if not t or not isinstance(t, str):
        return ""
    return " ".join((t or "").split()).strip().lower()


def _merge_jsonb_tag_maps(a: dict | None, b: dict | None) -> dict:
    """Merge two tag maps (code -> weight), taking max weight."""
    out = dict(a) if a else {}
    if not b:
        return out
    for k, v in b.items():
        if not k:
            continue
        w = 1.0
        if isinstance(v, (int, float)):
            w = float(v)
        elif v is True:
            w = 1.0
        w = max(0.0, min(1.0, w))
        out[k] = max(out.get(k, 0), w)
    return out


def sync_lexicon_and_document_tags(rag_url: str, chat_url: str, dry_run: bool = False) -> dict:
    """Copy policy_lexicon_meta, policy_lexicon_entries, document_tags, policy_line_tags from RAG → Chat. Returns summary."""
    summary = {"lexicon_meta": 0, "lexicon_entries": 0, "document_tags": 0, "policy_line_tags": 0, "errors": []}

    if dry_run:
        rag = _connect_db(rag_url)
        cur = rag.cursor()
        cur.execute("SELECT COUNT(*) FROM policy_lexicon_meta")
        summary["lexicon_meta"] = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM policy_lexicon_entries WHERE active = true")
        summary["lexicon_entries"] = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM document_tags")
        summary["document_tags"] = cur.fetchone()[0]
        try:
            cur.execute(
                "SELECT COUNT(*) FROM policy_lines WHERE p_tags IS NOT NULL OR d_tags IS NOT NULL OR j_tags IS NOT NULL"
            )
            summary["policy_line_tags"] = cur.fetchone()[0]
        except psycopg2.ProgrammingError:
            summary["policy_line_tags"] = 0  # policy_lines may not exist
        cur.close()
        rag.close()
        summary["dry_run"] = True
        return summary

    print("Connecting to RAG and Chat databases...", flush=True)
    rag = _connect_db(rag_url)
    rag_cur = rag.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    chat = _connect_db(chat_url)
    print("Connected. Starting sync...", flush=True)
    chat.autocommit = False
    chat_cur = chat.cursor()

    try:
        # 1. policy_lexicon_meta (replace with latest)
        print("[1/4] policy_lexicon_meta...", flush=True)
        rag_cur.execute(
            "SELECT id, revision, lexicon_version, lexicon_meta, created_at, updated_at "
            "FROM policy_lexicon_meta ORDER BY updated_at DESC NULLS LAST LIMIT 1"
        )
        meta_row = rag_cur.fetchone()
        if meta_row:
            chat_cur.execute("TRUNCATE TABLE policy_lexicon_meta")
            chat_cur.execute(
                """
                INSERT INTO policy_lexicon_meta (id, revision, lexicon_version, lexicon_meta, created_at, updated_at)
                VALUES (%s, %s, %s, %s, %s, %s)
                """,
                (
                    str(meta_row["id"]),
                    meta_row["revision"],
                    meta_row["lexicon_version"] or "v1",
                    json.dumps(meta_row["lexicon_meta"]) if isinstance(meta_row["lexicon_meta"], dict) else "{}",
                    meta_row["created_at"],
                    meta_row["updated_at"],
                ),
            )
            summary["lexicon_meta"] = 1
        print("[1/4] policy_lexicon_meta done", flush=True)

        # 2. policy_lexicon_entries (full replace of active entries)
        print("[2/4] policy_lexicon_entries...", flush=True)
        rag_cur.execute(
            "SELECT id, kind, code, parent_code, spec, active FROM policy_lexicon_entries WHERE active = true ORDER BY kind, code"
        )
        entries = rag_cur.fetchall()
        chat_cur.execute("TRUNCATE TABLE policy_lexicon_entries")
        for e in entries:
            spec_val = e["spec"]
            spec_json = json.dumps(spec_val) if isinstance(spec_val, dict) else "{}"
            chat_cur.execute(
                """
                INSERT INTO policy_lexicon_entries (id, kind, code, parent_code, spec, active, created_at, updated_at)
                VALUES (%s, %s, %s, %s, %s::jsonb, %s, NOW(), NOW())
                """,
                (str(uuid.uuid4()), e["kind"], e["code"], e.get("parent_code"), spec_json, True),
            )
        summary["lexicon_entries"] = len(entries)
        print(f"[2/4] policy_lexicon_entries done ({len(entries)} rows)", flush=True)

        # 3. document_tags (full replace)
        print("[3/4] document_tags...", flush=True)
        rag_cur.execute(
            "SELECT document_id, p_tags, d_tags, j_tags, lexicon_revision, tagged_at, created_at, updated_at "
            "FROM document_tags"
        )
        tags_rows = rag_cur.fetchall()
        chat_cur.execute("TRUNCATE TABLE document_tags")
        for row in tags_rows:
            def _to_jsonb(val):
                if val is None:
                    return "{}"
                return json.dumps(val) if isinstance(val, dict) else (val if isinstance(val, str) else "{}")

            p_tags = _to_jsonb(row.get("p_tags"))
            d_tags = _to_jsonb(row.get("d_tags"))
            j_tags = _to_jsonb(row.get("j_tags"))
            chat_cur.execute(
                """
                INSERT INTO document_tags (document_id, p_tags, d_tags, j_tags, lexicon_revision, tagged_at, created_at, updated_at)
                VALUES (%s, %s::jsonb, %s::jsonb, %s::jsonb, %s, %s, COALESCE(%s, NOW()), COALESCE(%s, NOW()))
                """,
                (
                    row["document_id"],
                    p_tags,
                    d_tags,
                    j_tags,
                    row.get("lexicon_revision"),
                    row.get("tagged_at"),
                    row.get("created_at"),
                    row.get("updated_at"),
                ),
            )
        summary["document_tags"] = len(tags_rows)
        print(f"[3/4] document_tags done ({len(tags_rows)} rows)", flush=True)

        # 4. policy_line_tags (from policy_lines; aggregated by document_id + normalized_text)
        try:
            print("[4/4] policy_line_tags: fetching from policy_lines...", flush=True)
            rag_cur.execute(
                "SELECT document_id, text, p_tags, d_tags, j_tags FROM policy_lines "
                "WHERE (p_tags IS NOT NULL OR d_tags IS NOT NULL OR j_tags IS NOT NULL)"
            )
            line_rows = rag_cur.fetchall()
            print(f"[4/4] policy_line_tags: fetched {len(line_rows)} rows, aggregating...", flush=True)
            # Aggregate by (document_id, normalized_text), merging tags
            merged: dict[tuple, dict] = {}
            batch_log = max(1, len(line_rows) // 10)  # log every 10%
            for i, r in enumerate(line_rows):
                doc_id = r.get("document_id")
                text = r.get("text") or ""
                norm = _normalize_text_for_match(text)
                if not doc_id or not norm:
                    continue
                key = (str(doc_id), norm)
                p = _merge_jsonb_tag_maps(merged.get(key, {}).get("p_tags"), r.get("p_tags"))
                d = _merge_jsonb_tag_maps(merged.get(key, {}).get("d_tags"), r.get("d_tags"))
                j = _merge_jsonb_tag_maps(merged.get(key, {}).get("j_tags"), r.get("j_tags"))
                merged[key] = {"p_tags": p, "d_tags": d, "j_tags": j}
                if (i + 1) % batch_log == 0:
                    print(f"[4/4] policy_line_tags: aggregated {i + 1}/{len(line_rows)} rows...", flush=True)

            print(f"[4/4] policy_line_tags: inserting {len(merged)} unique (doc_id, text) rows...", flush=True)
            chat_cur.execute("TRUNCATE TABLE policy_line_tags")
            insert_batch_log = max(1, len(merged) // 10)  # log every 10%
            for idx, ((doc_id, norm_text), tags) in enumerate(merged.items()):
                def _to_jsonb(val):
                    if not val:
                        return "{}"
                    return json.dumps(val) if isinstance(val, dict) else "{}"

                chat_cur.execute(
                    """
                    INSERT INTO policy_line_tags (document_id, normalized_text, p_tags, d_tags, j_tags)
                    VALUES (%s::uuid, %s, %s::jsonb, %s::jsonb, %s::jsonb)
                    ON CONFLICT (document_id, normalized_text) DO UPDATE SET
                        p_tags = EXCLUDED.p_tags,
                        d_tags = EXCLUDED.d_tags,
                        j_tags = EXCLUDED.j_tags
                    """,
                    (doc_id, norm_text, _to_jsonb(tags["p_tags"]), _to_jsonb(tags["d_tags"]), _to_jsonb(tags["j_tags"])),
                )
                if (idx + 1) % insert_batch_log == 0:
                    print(f"[4/4] policy_line_tags: inserted {idx + 1}/{len(merged)} rows...", flush=True)
            summary["policy_line_tags"] = len(merged)
            print(f"[4/4] policy_line_tags done ({len(merged)} rows)", flush=True)
        except psycopg2.ProgrammingError as e:
            if "policy_lines" in str(e) or "does not exist" in str(e).lower():
                summary["policy_line_tags"] = 0
            else:
                raise

        chat.commit()
    except Exception as e:
        chat.rollback()
        summary["errors"].append(str(e))
        raise
    finally:
        rag_cur.close()
        rag.close()
        chat_cur.close()
        chat.close()

    return summary


def main() -> int:
    dry_run = "--dry-run" in sys.argv
    verbose = "--verbose" in sys.argv or "-v" in sys.argv
    rag_url = _rag_database_url()
    chat_url = (os.environ.get("CHAT_DATABASE_URL") or os.environ.get("CHAT_RAG_DATABASE_URL") or "").strip()

    if not chat_url or "${" in chat_url:
        print("Set CHAT_DATABASE_URL or CHAT_RAG_DATABASE_URL (same as sync_mart_to_chat).", file=sys.stderr)
        return 1
    if not rag_url:
        print(
            "Set RAG_DATABASE_URL, or POSTGRES_HOST + POSTGRES_PASSWORD (to build RAG URL).",
            file=sys.stderr,
        )
        return 1

    try:
        result = sync_lexicon_and_document_tags(rag_url, chat_url, dry_run=dry_run)
        extra = f", policy_line_tags={result['policy_line_tags']}" if "policy_line_tags" in result else ""
        if verbose:
            try:
                conn = _connect_db(rag_url)
                cur = conn.cursor()
                cur.execute("SELECT current_database(), inet_server_addr()")
                row = cur.fetchone()
                print(f"[verbose] RAG source: db={row[0]}, host={row[1]}", flush=True)
                cur.close()
                conn.close()
            except Exception as e:
                print(f"[verbose] Could not get RAG db info: {e}", flush=True)
        if result.get("document_tags", 0) == 0 and result.get("policy_line_tags", 0) == 0:
            print(
                "\nNote: document_tags=0 and policy_line_tags=0. Ensure RAG_DATABASE_URL (or DATABASE_URL) "
                "points to mobius_rag where Path B has populated document_tags and policy_lines.",
                file=sys.stderr,
            )
        if dry_run:
            print(
                f"[DRY RUN] Would sync: lexicon_meta={result['lexicon_meta']}, "
                f"lexicon_entries={result['lexicon_entries']}, document_tags={result['document_tags']}{extra}",
                flush=True,
            )
        else:
            print(
                f"Synced RAG lexicon → Chat: meta={result['lexicon_meta']}, "
                f"entries={result['lexicon_entries']}, document_tags={result['document_tags']}{extra}",
                flush=True,
            )
        return 0
    except Exception as e:
        print(f"sync_rag_lexicon_to_chat failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
