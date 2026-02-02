#!/usr/bin/env python3
"""
Ingest rag_published_embeddings from RAG PostgreSQL into BigQuery landing_rag.rag_published_embeddings.
Run this before dbt run so the mart has data. Schedule this + dbt run together (e.g. Cloud Scheduler, Composer).

Env (required for Postgres):
  POSTGRES_HOST, POSTGRES_PORT (default 5432), POSTGRES_DB (default mobius_rag),
  POSTGRES_USER (default postgres), POSTGRES_PASSWORD

Env (optional for BigQuery):
  BQ_PROJECT (default mobiusos-new), BQ_LANDING_DATASET (default landing_rag), BQ_TABLE (default rag_published_embeddings)
  Uses Application Default Credentials for BigQuery.

Usage:
  python scripts/ingest_rag_to_landing.py
  # or from repo root with venv: ./scripts/land_and_dbt_run.sh
"""

import os
import sys
import json
from datetime import datetime
from pathlib import Path
from typing import Any, List, Optional

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


def _embedding_to_list(val: Any) -> Optional[List[float]]:
    """Convert pgvector/embedding column to list of floats for BigQuery ARRAY<FLOAT64>."""
    if val is None:
        return None
    if isinstance(val, list):
        return [float(x) for x in val]
    if hasattr(val, "__iter__") and not isinstance(val, (str, bytes)):
        return [float(x) for x in val]
    if isinstance(val, str):
        try:
            return [float(x) for x in json.loads(val)]
        except (json.JSONDecodeError, TypeError):
            pass
        try:
            import ast
            return [float(x) for x in ast.literal_eval(val)]
        except (ValueError, TypeError, SyntaxError):
            pass
    return None


def _row_to_bq(row: dict) -> dict:
    """Convert a Postgres row to BigQuery row (same keys; embedding -> list; timestamps -> ISO)."""
    out = {}
    for k, v in row.items():
        if k == "embedding":
            out[k] = _embedding_to_list(v)
        elif isinstance(v, datetime):
            out[k] = v.isoformat() if v else None
        else:
            out[k] = v
    return out


def main() -> int:
    host = os.environ.get("POSTGRES_HOST")
    password = os.environ.get("POSTGRES_PASSWORD")
    if not host or not password:
        print("Set POSTGRES_HOST and POSTGRES_PASSWORD.", file=sys.stderr)
        return 1

    port = int(os.environ.get("POSTGRES_PORT", "5432"))
    dbname = os.environ.get("POSTGRES_DB", "mobius_rag")
    user = os.environ.get("POSTGRES_USER", "postgres")

    bq_project = os.environ.get("BQ_PROJECT", "mobiusos-new")
    bq_dataset = os.environ.get("BQ_LANDING_DATASET", "landing_rag")
    bq_table = os.environ.get("BQ_TABLE", "rag_published_embeddings")
    table_id = f"{bq_project}.{bq_dataset}.{bq_table}"

    print("Connecting to PostgreSQL...", flush=True)
    try:
        conn = psycopg2.connect(
            host=host,
            port=port,
            dbname=dbname,
            user=user,
            password=password,
        )
    except Exception as e:
        print(f"PostgreSQL connection failed: {e}", file=sys.stderr)
        return 1

    rows_bq: List[dict] = []
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("SELECT * FROM rag_published_embeddings ORDER BY id")
            for row in cur:
                rows_bq.append(_row_to_bq(dict(row)))
    finally:
        conn.close()

    print(f"Fetched {len(rows_bq)} rows from PostgreSQL.", flush=True)

    if not rows_bq:
        print("No rows to load. BigQuery table will be truncated if you use WRITE_TRUNCATE.", flush=True)
        # Option: still truncate landing table so dbt run sees empty table
        # Here we skip load and let user decide; or we could run a delete job.
        # For "full refresh" semantics we truncate. We need to run a BQ job to truncate.
        client = bigquery.Client(project=bq_project)
        client.query(f"TRUNCATE TABLE `{table_id}`").result()
        print("Truncated BigQuery landing table.", flush=True)
        return 0

    client = bigquery.Client(project=bq_project)
    job_config = bigquery.LoadJobConfig(
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        autodetect=False,
        schema=[
            bigquery.SchemaField("id", "STRING", mode="REQUIRED"),
            bigquery.SchemaField("document_id", "STRING", mode="REQUIRED"),
            bigquery.SchemaField("source_type", "STRING", mode="REQUIRED"),
            bigquery.SchemaField("source_id", "STRING", mode="REQUIRED"),
            bigquery.SchemaField("embedding", "FLOAT64", mode="REPEATED"),
            bigquery.SchemaField("model", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("created_at", "TIMESTAMP", mode="REQUIRED"),
            bigquery.SchemaField("text", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("page_number", "INTEGER", mode="NULLABLE"),
            bigquery.SchemaField("paragraph_index", "INTEGER", mode="NULLABLE"),
            bigquery.SchemaField("section_path", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("chapter_path", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("summary", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("document_filename", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("document_display_name", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("document_authority_level", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("document_effective_date", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("document_termination_date", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("document_payer", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("document_state", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("document_program", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("document_status", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("document_created_at", "TIMESTAMP", mode="NULLABLE"),
            bigquery.SchemaField("document_review_status", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("document_reviewed_at", "TIMESTAMP", mode="NULLABLE"),
            bigquery.SchemaField("document_reviewed_by", "STRING", mode="NULLABLE"),
            bigquery.SchemaField("content_sha", "STRING", mode="REQUIRED"),
            bigquery.SchemaField("updated_at", "TIMESTAMP", mode="REQUIRED"),
            bigquery.SchemaField("source_verification_status", "STRING", mode="NULLABLE"),
        ],
    )

    print(f"Loading {len(rows_bq)} rows into BigQuery {table_id}...", flush=True)
    job = client.load_table_from_json(rows_bq, table_id, job_config=job_config)
    try:
        job.result()
    except Exception as e:
        print(f"BigQuery load failed: {e}", file=sys.stderr)
        return 1

    print(f"Loaded {job.output_rows} rows into {table_id}.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
