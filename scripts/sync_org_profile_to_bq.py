#!/usr/bin/env python3
"""
Sync org_profile and confirmed_npis from Chat PostgreSQL into BigQuery landing tables.
Run this before dbt run so the financial benchmarking models have proper org identity.

Creates two landing tables in BQ_LANDING_MEDICAID_DATASET:
  1. org_profile_landing   — one row per org (identity, aliases, skill flags)
  2. org_npi_map_landing   — one row per org × NPI (flattened from confirmed_npis JSONB)

Env (Postgres — provide CHAT_DATABASE_URL or individual vars):
  CHAT_DATABASE_URL  — e.g. postgresql://user:pass@host:5432/chat
  -- OR --
  POSTGRES_HOST, POSTGRES_PORT (default 5432), POSTGRES_PASSWORD,
  POSTGRES_USER (default postgres), POSTGRES_DB_CHAT (default chat)

Env (BigQuery — optional):
  BQ_PROJECT (default mobius-os-dev)
  BQ_LANDING_MEDICAID_DATASET (default landing_medicaid_npi_dev)

Usage:
  python scripts/sync_org_profile_to_bq.py
"""

import os
import sys
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, List, Optional
from urllib.parse import urlparse, unquote

_project_root = Path(__file__).resolve().parent.parent
try:
    from dotenv import load_dotenv
    load_dotenv(_project_root / ".env")
except ImportError:
    pass

try:
    import psycopg2
    from psycopg2.extras import RealDictCursor
except ImportError:
    print("Install psycopg2-binary: pip install psycopg2-binary", file=sys.stderr)
    sys.exit(1)

try:
    from google.cloud import bigquery
except ImportError:
    print("Install google-cloud-bigquery: pip install google-cloud-bigquery", file=sys.stderr)
    sys.exit(1)


# ── BQ schemas ────────────────────────────────────────────────────────────────

ORG_PROFILE_SCHEMA = [
    bigquery.SchemaField("org_slug", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("org_name", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("org_name_aliases", "STRING", mode="NULLABLE"),  # JSON array
    bigquery.SchemaField("npi_count", "INT64", mode="REQUIRED"),
    bigquery.SchemaField("confirmed_at", "TIMESTAMP", mode="NULLABLE"),
    bigquery.SchemaField("confirmed_by", "STRING", mode="NULLABLE"),
    bigquery.SchemaField("last_refreshed_at", "TIMESTAMP", mode="NULLABLE"),
    bigquery.SchemaField("active_skills", "STRING", mode="NULLABLE"),  # JSON object
    bigquery.SchemaField("synced_at", "TIMESTAMP", mode="REQUIRED"),
]

ORG_NPI_MAP_SCHEMA = [
    bigquery.SchemaField("org_slug", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("org_name", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("npi", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("npi_name", "STRING", mode="NULLABLE"),
    bigquery.SchemaField("entity_type", "STRING", mode="NULLABLE"),
    bigquery.SchemaField("taxonomy_code", "STRING", mode="NULLABLE"),
    bigquery.SchemaField("source", "STRING", mode="NULLABLE"),
    bigquery.SchemaField("npi_confirmed_at", "TIMESTAMP", mode="NULLABLE"),
    bigquery.SchemaField("synced_at", "TIMESTAMP", mode="REQUIRED"),
]


def _parse_chat_db_url(url: str) -> dict:
    """Parse CHAT_DATABASE_URL into psycopg2 connect kwargs."""
    parsed = urlparse(url)
    return {
        "host": parsed.hostname,
        "port": parsed.port or 5432,
        "dbname": parsed.path.lstrip("/") or "chat",
        "user": unquote(parsed.username) if parsed.username else "postgres",
        "password": unquote(parsed.password) if parsed.password else "",
    }


def _ts(val: Any) -> Optional[str]:
    """Convert a timestamp to ISO string for BQ, or None."""
    if val is None:
        return None
    if isinstance(val, datetime):
        return val.isoformat()
    if isinstance(val, str):
        return val
    return str(val)


def _json_str(val: Any) -> Optional[str]:
    """Serialize a JSONB value to JSON string for BQ STRING column."""
    if val is None:
        return None
    if isinstance(val, str):
        return val
    return json.dumps(val, default=str)


def _connect_chat_pg() -> "psycopg2.connection":
    """Connect to the Chat PostgreSQL database."""
    chat_url = os.environ.get("CHAT_DATABASE_URL")
    if chat_url:
        kwargs = _parse_chat_db_url(chat_url)
    else:
        host = os.environ.get("POSTGRES_HOST")
        password = os.environ.get("POSTGRES_PASSWORD")
        if not host or not password:
            print(
                "Set CHAT_DATABASE_URL or (POSTGRES_HOST + POSTGRES_PASSWORD).",
                file=sys.stderr,
            )
            sys.exit(1)
        kwargs = {
            "host": host,
            "port": int(os.environ.get("POSTGRES_PORT", "5432")),
            "dbname": os.environ.get("POSTGRES_DB_CHAT", "chat"),
            "user": os.environ.get("POSTGRES_USER", "postgres"),
            "password": password,
        }
    return psycopg2.connect(**kwargs)


def main() -> int:
    bq_project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    bq_dataset = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")

    profile_table_id = f"{bq_project}.{bq_dataset}.org_profile_landing"
    npi_map_table_id = f"{bq_project}.{bq_dataset}.org_npi_map_landing"

    now_iso = datetime.now(timezone.utc).isoformat()

    # ── 1. Read from Postgres ─────────────────────────────────────────────────
    print("Connecting to Chat PostgreSQL...", flush=True)
    try:
        conn = _connect_chat_pg()
    except Exception as e:
        print(f"PostgreSQL connection failed: {e}", file=sys.stderr)
        return 1

    profile_rows: List[dict] = []
    npi_map_rows: List[dict] = []

    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                "SELECT org_slug, org_name, org_name_aliases, confirmed_npis, "
                "       org_identifiers, active_skills, confirmed_at, confirmed_by, "
                "       last_refreshed_at "
                "FROM org_profile ORDER BY id"
            )
            for row in cur:
                row = dict(row)
                confirmed_npis = row.get("confirmed_npis") or []
                if isinstance(confirmed_npis, str):
                    confirmed_npis = json.loads(confirmed_npis)

                # Profile row
                profile_rows.append({
                    "org_slug": row["org_slug"],
                    "org_name": row["org_name"],
                    "org_name_aliases": _json_str(row.get("org_name_aliases")),
                    "npi_count": len(confirmed_npis),
                    "confirmed_at": _ts(row.get("confirmed_at")),
                    "confirmed_by": row.get("confirmed_by"),
                    "last_refreshed_at": _ts(row.get("last_refreshed_at")),
                    "active_skills": _json_str(row.get("active_skills")),
                    "synced_at": now_iso,
                })

                # NPI map rows (one per confirmed NPI)
                for npi_rec in confirmed_npis:
                    npi_val = npi_rec.get("npi", "")
                    if not npi_val:
                        continue
                    npi_map_rows.append({
                        "org_slug": row["org_slug"],
                        "org_name": row["org_name"],
                        "npi": str(npi_val),
                        "npi_name": npi_rec.get("name", ""),
                        "entity_type": npi_rec.get("entity_type", ""),
                        "taxonomy_code": npi_rec.get("taxonomy_code", ""),
                        "source": npi_rec.get("source", ""),
                        "npi_confirmed_at": _ts(npi_rec.get("confirmed_at")),
                        "synced_at": now_iso,
                    })
    finally:
        conn.close()

    print(
        f"Fetched {len(profile_rows)} orgs, {len(npi_map_rows)} NPI mappings from PostgreSQL.",
        flush=True,
    )

    if not profile_rows:
        print("No orgs found — truncating BQ landing tables.", flush=True)
        client = bigquery.Client(project=bq_project)
        for tid in [profile_table_id, npi_map_table_id]:
            try:
                client.query(f"TRUNCATE TABLE `{tid}`").result()
            except Exception:
                pass  # table may not exist yet
        return 0

    # ── 2. Load into BigQuery ─────────────────────────────────────────────────
    client = bigquery.Client(project=bq_project)

    # org_profile_landing
    print(f"Loading {len(profile_rows)} orgs into {profile_table_id}...", flush=True)
    job = client.load_table_from_json(
        profile_rows,
        profile_table_id,
        job_config=bigquery.LoadJobConfig(
            write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
            autodetect=False,
            schema=ORG_PROFILE_SCHEMA,
        ),
    )
    try:
        job.result()
    except Exception as e:
        print(f"BigQuery load failed (org_profile_landing): {e}", file=sys.stderr)
        return 1
    print(f"  → {job.output_rows} rows loaded.", flush=True)

    # org_npi_map_landing
    print(f"Loading {len(npi_map_rows)} NPI mappings into {npi_map_table_id}...", flush=True)
    job = client.load_table_from_json(
        npi_map_rows,
        npi_map_table_id,
        job_config=bigquery.LoadJobConfig(
            write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
            autodetect=False,
            schema=ORG_NPI_MAP_SCHEMA,
        ),
    )
    try:
        job.result()
    except Exception as e:
        print(f"BigQuery load failed (org_npi_map_landing): {e}", file=sys.stderr)
        return 1
    print(f"  → {job.output_rows} rows loaded.", flush=True)

    print("Org profile sync complete.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
