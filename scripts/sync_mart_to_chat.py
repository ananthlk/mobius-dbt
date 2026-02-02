#!/usr/bin/env python3
"""
Sync BigQuery mart (published_rag_embeddings) to Mobius Chat: Postgres (metadata) + Vertex AI Vector Search (embeddings + filter metadata).
Run after dbt run/test. Part of the full pipeline: ingest → dbt run → dbt test → sync → write run output.

Env (required):
  BQ_PROJECT, BQ_DATASET (mart location, e.g. mobiusos-new, mobius_rag_dev)
  CHAT_DATABASE_URL (Chat Postgres: MUST be the SAME DB as Mobius-Chat CHAT_RAG_DATABASE_URL,
    e.g. postgresql://postgres:***@34.59.175.121:5432/mobius_chat; otherwise Chat gets 0 rows for Vertex ids)
  VERTEX_PROJECT, VERTEX_REGION, VERTEX_INDEX_ID (Vertex AI Vector Search index)

Env (optional):
  VERTEX_INDEX_ENDPOINT_ID (streaming: deployed index endpoint)
  VERTEX_INDEX_MODE (streaming|batch; default: streaming)
  GCS_BUCKET, GCS_PREFIX (batch: export mart to GCS before index update)
  BQ_SYNC_RUNS_TABLE (default: <BQ_DATASET>.sync_runs for run output)

Usage:
  python scripts/sync_mart_to_chat.py
  # or from pipeline: ./scripts/land_and_dbt_run.sh (includes this step)
"""

import os
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

_project_root = Path(__file__).resolve().parent.parent
try:
    from dotenv import load_dotenv
    load_dotenv(_project_root / ".env")
except ImportError:
    pass

try:
    from google.cloud import bigquery
except ImportError:
    print("Install google-cloud-bigquery: pip install google-cloud-bigquery", file=sys.stderr)
    sys.exit(1)

try:
    import psycopg2
    from psycopg2.extras import execute_values
except ImportError:
    print("Install psycopg2-binary: pip install psycopg2-binary", file=sys.stderr)
    sys.exit(1)

try:
    from google.cloud import aiplatform
except ImportError:
    print("Install google-cloud-aiplatform: pip install google-cloud-aiplatform", file=sys.stderr)
    sys.exit(1)

try:
    from google.cloud import storage
except ImportError:
    storage = None  # only needed for batch mode


def _read_mart(bq_client: bigquery.Client, project: str, dataset: str) -> List[Dict[str, Any]]:
    """Read all rows from BigQuery mart published_rag_embeddings."""
    table_id = f"{project}.{dataset}.published_rag_embeddings"
    print(f"Reading BigQuery mart: {table_id}...", flush=True)
    query = f"SELECT * FROM `{table_id}`"
    rows = []
    for row in bq_client.query(query).result():
        rows.append(dict(row))
    print(f"Read {len(rows)} rows from mart.", flush=True)
    return rows


def _write_postgres_metadata(rows: List[Dict[str, Any]], database_url: str) -> int:
    """Write metadata (all columns except embedding) to Chat Postgres published_rag_metadata. Returns rows written."""
    print(f"Writing {len(rows)} rows to Chat Postgres (metadata only)...", flush=True)
    conn = psycopg2.connect(database_url)
    conn.autocommit = False
    try:
        cur = conn.cursor()
        # Columns: all mart columns except embedding
        cols = [
            "id", "document_id", "source_type", "source_id", "model", "created_at", "text",
            "page_number", "paragraph_index", "section_path", "chapter_path", "summary",
            "document_filename", "document_display_name", "document_authority_level",
            "document_effective_date", "document_termination_date", "document_payer",
            "document_state", "document_program", "document_status", "document_created_at",
            "document_review_status", "document_reviewed_at", "document_reviewed_by",
            "content_sha", "updated_at", "source_verification_status"
        ]
        values = [tuple(row.get(c) for c in cols) for row in rows]
        
        # Upsert: ON CONFLICT (id) DO UPDATE
        placeholders = ",".join(["%s"] * len(cols))
        updates = ", ".join([f"{c} = EXCLUDED.{c}" for c in cols if c != "id"])
        sql = f"""
            INSERT INTO published_rag_metadata ({", ".join(cols)})
            VALUES %s
            ON CONFLICT (id) DO UPDATE SET {updates}
        """
        execute_values(cur, sql, values, page_size=500)
        conn.commit()
        print(f"Wrote {len(rows)} rows to Postgres.", flush=True)
        return len(rows)
    except Exception as e:
        conn.rollback()
        print(f"Postgres write failed: {e}", file=sys.stderr)
        raise
    finally:
        conn.close()


def _upsert_vertex_vectors(rows: List[Dict[str, Any]], project: str, region: str, index_id: str, endpoint_id: Optional[str]) -> int:
    """Upsert vectors + metadata to Vertex AI Vector Search. Returns rows upserted."""
    print(f"Upserting {len(rows)} vectors to Vertex AI Vector Search (index {index_id})...", flush=True)
    
    aiplatform.init(project=project, location=region)
    
    # Build datapoints: id, embedding, restricts (filter metadata)
    datapoints = []
    for row in rows:
        emb = row.get("embedding")
        if not emb or not isinstance(emb, list):
            print(f"Skipping row id={row.get('id')}: no valid embedding", file=sys.stderr)
            continue
        
        # Metadata for filtering and context
        restricts = [
            {"namespace": "document_payer", "allow_list": [row.get("document_payer") or ""]},
            {"namespace": "document_state", "allow_list": [row.get("document_state") or ""]},
            {"namespace": "document_program", "allow_list": [row.get("document_program") or ""]},
            {"namespace": "document_authority_level", "allow_list": [row.get("document_authority_level") or ""]},
            {"namespace": "source_type", "allow_list": [row.get("source_type") or ""]},
        ]
        
        # Additional metadata (not for filtering, but for display/context)
        crowding_tag = str(row.get("document_id") or "")  # Optional: group by document for diversity
        
        datapoints.append({
            "datapoint_id": str(row.get("id")),
            "feature_vector": emb,
            "restricts": restricts,
            "crowding_tag": crowding_tag,
        })
    
    if not datapoints:
        print("No valid datapoints to upsert.", flush=True)
        return 0
    
    # Upsert to index (batch API)
    # Note: Vertex Vector Search upsert API varies by index type (streaming vs batch).
    # For streaming index: use MatchingEngineIndexEndpoint.upsert_datapoints
    # For batch: export to GCS then rebuild index (not real-time).
    # This script assumes streaming index and uses the upsert API.
    
    try:
        index = aiplatform.MatchingEngineIndex(index_name=index_id)
        # If using deployed endpoint:
        if endpoint_id:
            endpoint = aiplatform.MatchingEngineIndexEndpoint(index_endpoint_name=endpoint_id)
            # Upsert via endpoint (streaming)
            endpoint.upsert_datapoints(datapoints=datapoints)
        else:
            # Direct index upsert (if supported by index type)
            # Note: some index types require endpoint; adjust based on your Vertex setup
            print("VERTEX_INDEX_ENDPOINT_ID not set; assuming direct index upsert (may fail for some index types).", file=sys.stderr)
            # Fallback: use index.update_embeddings or similar (check Vertex API for your index type)
            # For now, raise an error and require endpoint_id
            raise ValueError("VERTEX_INDEX_ENDPOINT_ID required for upsert. Set it in env.")
        
        print(f"Upserted {len(datapoints)} vectors to Vertex.", flush=True)
        return len(datapoints)
    except Exception as e:
        print(f"Vertex upsert failed: {e}", file=sys.stderr)
        raise


def _export_to_gcs(rows: List[Dict[str, Any]], bucket_name: str, prefix: str, project: str) -> str:
    """Export mart rows to GCS as JSON lines (Vertex batch format). Returns gs:// URI."""
    import json
    if not storage:
        raise ImportError("Install google-cloud-storage for batch mode")
    print(f"Exporting {len(rows)} rows to gs://{bucket_name}/{prefix}...", flush=True)
    client = storage.Client(project=project)
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(f"{prefix}/data.json")
    lines = []
    for row in rows:
        emb = row.get("embedding")
        if not emb or not isinstance(emb, list):
            continue
        restricts = [
            {"namespace": "document_payer", "allow": [str(row.get("document_payer") or "")]},
            {"namespace": "document_state", "allow": [str(row.get("document_state") or "")]},
            {"namespace": "document_program", "allow": [str(row.get("document_program") or "")]},
            {"namespace": "document_authority_level", "allow": [str(row.get("document_authority_level") or "")]},
            {"namespace": "source_type", "allow": [str(row.get("source_type") or "")]},
        ]
        rec = {"id": str(row.get("id")), "embedding": [float(x) for x in emb], "restricts": restricts, "crowding_tag": str(row.get("document_id") or "")}
        lines.append(json.dumps(rec))
    blob.upload_from_string("\n".join(lines), content_type="application/json")
    gcs_uri = f"gs://{bucket_name}/{prefix}"
    print(f"Exported to {gcs_uri}", flush=True)
    return gcs_uri


def _update_vertex_batch_index(rows: List[Dict[str, Any]], project: str, region: str, index_id: str, gcs_bucket: str, gcs_prefix: str) -> int:
    """Export mart to GCS and update batch index. Returns rows exported."""
    gcs_uri = _export_to_gcs(rows, gcs_bucket, gcs_prefix, project)
    print(f"Updating batch index {index_id}...", flush=True)
    aiplatform.init(project=project, location=region)
    index = aiplatform.MatchingEngineIndex(index_name=index_id)
    index.update_embeddings(contents_delta_uri=gcs_uri, is_complete_overwrite=True)
    print(f"Batch index update started.", flush=True)
    return len([r for r in rows if r.get("embedding")])


def _write_sync_run_output(
    bq_client: bigquery.Client,
    run_id: str,
    started_at: datetime,
    finished_at: datetime,
    mart_rows_read: int,
    postgres_rows_written: int,
    vector_rows_upserted: int,
    status: str,
    error_message: Optional[str],
    bq_project: str,
    bq_dataset: str,
    chat_database_url: Optional[str],
) -> None:
    """Write sync run output to BigQuery sync_runs and optionally Chat Postgres sync_runs."""
    sync_runs_table = os.environ.get("BQ_SYNC_RUNS_TABLE", f"{bq_dataset}.sync_runs")
    table_id = f"{bq_project}.{sync_runs_table}"
    
    row = {
        "run_id": run_id,
        "started_at": started_at.isoformat(),
        "finished_at": finished_at.isoformat(),
        "mart_rows_read": mart_rows_read,
        "postgres_rows_written": postgres_rows_written,
        "vector_rows_upserted": vector_rows_upserted,
        "status": status,
        "error_message": error_message,
    }
    
    # Write to BigQuery
    print(f"Writing run output to BigQuery {table_id}...", flush=True)
    try:
        job = bq_client.insert_rows_json(table_id, [row])
        if job:
            print(f"BigQuery insert errors: {job}", file=sys.stderr)
        else:
            print(f"Wrote run output to BigQuery.", flush=True)
    except Exception as e:
        print(f"Failed to write run output to BigQuery: {e}", file=sys.stderr)
    
    # Write to Chat Postgres (optional)
    if chat_database_url:
        try:
            conn = psycopg2.connect(chat_database_url)
            cur = conn.cursor()
            cur.execute(
                """
                INSERT INTO sync_runs (run_id, started_at, finished_at, mart_rows_read, postgres_rows_written, vector_rows_upserted, status, error_message)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (run_id, started_at, finished_at, mart_rows_read, postgres_rows_written, vector_rows_upserted, status, error_message),
            )
            conn.commit()
            conn.close()
            print(f"Wrote run output to Chat Postgres.", flush=True)
        except Exception as e:
            print(f"Failed to write run output to Chat Postgres: {e}", file=sys.stderr)


def main() -> int:
    bq_project = os.environ.get("BQ_PROJECT")
    bq_dataset = os.environ.get("BQ_DATASET")
    chat_db_url = os.environ.get("CHAT_DATABASE_URL")
    vertex_project = os.environ.get("VERTEX_PROJECT")
    vertex_region = os.environ.get("VERTEX_REGION")
    vertex_index_id = os.environ.get("VERTEX_INDEX_ID")
    vertex_endpoint_id = os.environ.get("VERTEX_INDEX_ENDPOINT_ID")
    
    if not all([bq_project, bq_dataset, chat_db_url, vertex_project, vertex_region, vertex_index_id]):
        print("Set: BQ_PROJECT, BQ_DATASET, CHAT_DATABASE_URL, VERTEX_PROJECT, VERTEX_REGION, VERTEX_INDEX_ID", file=sys.stderr)
        return 1
    
    run_id = str(uuid.uuid4())
    started_at = datetime.now(timezone.utc)
    mart_rows_read = 0
    postgres_rows_written = 0
    vector_rows_upserted = 0
    status = "failure"
    error_message = None
    
    bq_client = bigquery.Client(project=bq_project)
    
    try:
        # 1. Read mart
        rows = _read_mart(bq_client, bq_project, bq_dataset)
        mart_rows_read = len(rows)
        
        if not rows:
            print("No rows in mart; skipping sync.", flush=True)
            status = "success"
            return 0
        
        # 2. Write metadata to Chat Postgres
        postgres_rows_written = _write_postgres_metadata(rows, chat_db_url)
        
        # 3. Write vectors to Vertex (streaming upsert or batch update)
        vertex_mode = os.environ.get("VERTEX_INDEX_MODE", "streaming").lower()
        gcs_bucket = os.environ.get("GCS_BUCKET")
        gcs_prefix = os.environ.get("GCS_PREFIX", "chat_rag_index")
        if vertex_mode == "batch" and gcs_bucket:
            vector_rows_upserted = _update_vertex_batch_index(rows, vertex_project, vertex_region, vertex_index_id, gcs_bucket, gcs_prefix)
        else:
            vector_rows_upserted = _upsert_vertex_vectors(rows, vertex_project, vertex_region, vertex_index_id, vertex_endpoint_id)
        
        status = "success"
        print(f"Sync complete: {mart_rows_read} rows read, {postgres_rows_written} to Postgres, {vector_rows_upserted} to Vertex.", flush=True)
        return 0
    
    except Exception as e:
        error_message = str(e)
        print(f"Sync failed: {e}", file=sys.stderr)
        return 1
    
    finally:
        finished_at = datetime.now(timezone.utc)
        _write_sync_run_output(
            bq_client, run_id, started_at, finished_at,
            mart_rows_read, postgres_rows_written, vector_rows_upserted,
            status, error_message,
            bq_project, bq_dataset, chat_db_url,
        )


if __name__ == "__main__":
    sys.exit(main())
