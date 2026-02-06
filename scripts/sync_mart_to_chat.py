#!/usr/bin/env python3
"""
Sync BigQuery mart (published_rag_embeddings) to Mobius Chat: Postgres (metadata) + Vertex AI Vector Search (embeddings + filter metadata).
Run after dbt run/test. Part of the full pipeline: ingest → dbt run → dbt test → sync → write run output.

Env (required):
  BQ_PROJECT, BQ_DATASET (mart location, e.g. mobiusos-new, mobius_rag_dev)
  CHAT_DATABASE_URL (Chat Postgres: MUST be the SAME DB as Mobius-Chat CHAT_RAG_DATABASE_URL,
    e.g. postgresql://postgres:***@34.59.175.121:5432/mobius_chat; otherwise Chat gets 0 rows for Vertex ids)
  VERTEX_PROJECT, VERTEX_REGION, VERTEX_INDEX_ID (Vertex AI Vector Search index)

Env (required for Vertex):
  GCS_BUCKET: bucket for exporting embeddings before index update (batch update only; no stream update).
Env (optional):
  GCS_PREFIX (default: chat_rag_index): prefix under GCS_BUCKET for export.
  BQ_SYNC_RUNS_TABLE (default: <BQ_DATASET>.sync_runs for run output)

Destination environments:
  --dest staging  Use DEST_STAGING_* env vars (staging Cloud SQL via proxy)
  --dest prod     Use DEST_PROD_* env vars
  (default)       Use unprefixed env vars (CHAT_DATABASE_URL, VERTEX_*, etc.)

Usage:
  python scripts/sync_mart_to_chat.py                    # default destination
  python scripts/sync_mart_to_chat.py --dest staging     # sync to staging
  python scripts/sync_mart_to_chat.py --dest prod        # sync to prod
  python scripts/sync_mart_to_chat.py --postgres-only    # skip Vertex update (metadata only)
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


def _read_watermark(bq_client: bigquery.Client, project: str, dataset: str) -> Optional[datetime]:
    """Return last_synced updated_at from sync_watermark, or None if first run."""
    table_id = f"{project}.{dataset}.sync_watermark"
    try:
        query = f"SELECT last_updated_at FROM `{table_id}` LIMIT 1"
        for row in bq_client.query(query).result():
            val = row.get("last_updated_at")
            if val is not None:
                return val if isinstance(val, datetime) else datetime.fromisoformat(str(val).replace("Z", "+00:00"))
        return None
    except Exception:
        return None


def _write_watermark(bq_client: bigquery.Client, project: str, dataset: str, last_updated_at: datetime) -> None:
    """Set sync_watermark.last_updated_at (single row, id=1). Insert or update."""
    table_id = f"{project}.{dataset}.sync_watermark"
    ts = last_updated_at.isoformat()
    job_config = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("ts", "TIMESTAMP", ts)]
    )
    query = f"""
    MERGE `{table_id}` AS t
    USING (SELECT 1 AS id, @ts AS last_updated_at) AS s
    ON t.id = s.id
    WHEN MATCHED THEN UPDATE SET last_updated_at = s.last_updated_at
    WHEN NOT MATCHED THEN INSERT (id, last_updated_at) VALUES (s.id, s.last_updated_at)
    """
    bq_client.query(query, job_config=job_config).result()
    print(f"Updated sync watermark to {ts}", flush=True)


def _read_mart(
    bq_client: bigquery.Client, project: str, dataset: str, since_updated_at: Optional[datetime] = None
) -> List[Dict[str, Any]]:
    """Read rows from BigQuery mart. If since_updated_at set, only rows with updated_at > since (incremental)."""
    table_id = f"{project}.{dataset}.published_rag_embeddings"
    if since_updated_at:
        job_config = bigquery.QueryJobConfig(
            query_parameters=[bigquery.ScalarQueryParameter("since", "TIMESTAMP", since_updated_at.isoformat())]
        )
        query = f"SELECT * FROM `{table_id}` WHERE updated_at > @since"
        print(f"Reading BigQuery mart (incremental since {since_updated_at.isoformat()}): {table_id}...", flush=True)
        job = bq_client.query(query, job_config=job_config)
    else:
        query = f"SELECT * FROM `{table_id}`"
        print(f"Reading BigQuery mart (full): {table_id}...", flush=True)
        job = bq_client.query(query)
    rows = []
    for row in job.result():
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
    
    # Upsert to index: MatchingEngineIndex.upsert_datapoints (REST: indexes.upsertDatapoints).
    # The endpoint is for queries (find_neighbors); upsert is on the Index resource.
    
    try:
        from google.cloud.aiplatform_v1.types import index as index_types

        def _to_dp(d: Dict[str, Any]) -> index_types.IndexDatapoint:
            rid = str(d.get("datapoint_id") or "")
            vec = d.get("feature_vector") or []
            # Convert restricts dicts to proto Restrictions
            restr = []
            for r in (d.get("restricts") or []):
                if not isinstance(r, dict):
                    continue
                ns = str(r.get("namespace") or "").strip()
                allow = r.get("allow_list") or r.get("allow") or []
                deny = r.get("deny_list") or r.get("deny") or []
                if not ns:
                    continue
                restr.append(index_types.IndexDatapoint.Restriction(
                    namespace=ns,
                    allow_list=[str(x) for x in allow if x is not None and str(x) != ""],
                    deny_list=[str(x) for x in deny if x is not None and str(x) != ""],
                ))
            tag = d.get("crowding_tag")
            crowd = None
            if isinstance(tag, str) and tag.strip():
                crowd = index_types.IndexDatapoint.CrowdingTag(crowding_attribute=tag.strip())
            return index_types.IndexDatapoint(
                datapoint_id=rid,
                feature_vector=[float(x) for x in vec],
                restricts=restr,
                crowding_tag=crowd,
            )

        index = aiplatform.MatchingEngineIndex(index_name=index_id)
        # Upsert in chunks to avoid request size limits
        batch_size = int(os.environ.get("VERTEX_UPSERT_BATCH_SIZE", "500"))
        total = 0
        for i in range(0, len(datapoints), batch_size):
            batch = datapoints[i : i + batch_size]
            proto_batch = [_to_dp(d) for d in batch]
            index.upsert_datapoints(datapoints=proto_batch)
            total += len(proto_batch)
            print(f"  upserted {total}/{len(datapoints)}", flush=True)
        print(f"Upserted {total} vectors to Vertex.", flush=True)
        return total
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


def _get_dest_env(dest: str, key: str, fallback_key: str | None = None) -> str | None:
    """Get env var for destination. If dest is set, try DEST_{DEST}_{KEY} first, then fallback."""
    if dest:
        prefixed = f"DEST_{dest.upper()}_{key}"
        val = os.environ.get(prefixed)
        if val:
            return val
    # Fallback to unprefixed or provided fallback key
    return os.environ.get(fallback_key or key)


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description="Sync BigQuery mart to Chat Postgres + Vertex")
    parser.add_argument("--dest", choices=["staging", "prod"], default=None,
                        help="Destination environment (uses DEST_STAGING_* or DEST_PROD_* env vars)")
    parser.add_argument("--postgres-only", action="store_true",
                        help="Only sync to Postgres, skip Vertex index update")
    args = parser.parse_args()
    
    dest = args.dest
    postgres_only = args.postgres_only
    
    # BigQuery source (always unprefixed)
    bq_project = os.environ.get("BQ_PROJECT")
    bq_dataset = os.environ.get("BQ_DATASET")
    
    # Destination config (prefixed if --dest is set)
    chat_db_url = _get_dest_env(dest, "CHAT_DATABASE_URL")
    vertex_project = _get_dest_env(dest, "VERTEX_PROJECT")
    vertex_region = _get_dest_env(dest, "VERTEX_REGION")
    vertex_index_id = _get_dest_env(dest, "VERTEX_INDEX_ID")
    vertex_endpoint_id = _get_dest_env(dest, "VERTEX_INDEX_ENDPOINT_ID")
    vertex_index_mode = (_get_dest_env(dest, "VERTEX_INDEX_MODE") or os.environ.get("VERTEX_INDEX_MODE") or "batch").strip().lower()
    
    dest_label = f" (dest={dest})" if dest else ""
    print(f"Sync target{dest_label}: Postgres={bool(chat_db_url)} Vertex={bool(vertex_index_id) and not postgres_only}", flush=True)
    
    required = [bq_project, bq_dataset, chat_db_url]
    if not postgres_only:
        required.extend([vertex_project, vertex_region, vertex_index_id])
    
    if not all(required):
        missing = []
        if not bq_project: missing.append("BQ_PROJECT")
        if not bq_dataset: missing.append("BQ_DATASET")
        prefix = f"DEST_{dest.upper()}_" if dest else ""
        if not chat_db_url: missing.append(f"{prefix}CHAT_DATABASE_URL")
        if not postgres_only:
            if not vertex_project: missing.append(f"{prefix}VERTEX_PROJECT")
            if not vertex_region: missing.append(f"{prefix}VERTEX_REGION")
            if not vertex_index_id: missing.append(f"{prefix}VERTEX_INDEX_ID")
        print(f"Missing env vars: {', '.join(missing)}", file=sys.stderr)
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
        # 1. Read watermark (incremental: only rows with updated_at > last_synced)
        since = _read_watermark(bq_client, bq_project, bq_dataset)
        if since:
            print(f"Incremental sync since {since.isoformat()}", flush=True)
        else:
            print("Full sync (no watermark yet)", flush=True)

        # 2. Read mart (full or delta)
        rows = _read_mart(bq_client, bq_project, bq_dataset, since_updated_at=since)
        mart_rows_read = len(rows)

        if not rows:
            print("No new/updated rows to sync.", flush=True)
            status = "success"
            return 0

        # 3. Write metadata to Chat Postgres
        postgres_rows_written = _write_postgres_metadata(rows, chat_db_url)

        # 4. Write vectors to Vertex (streaming upsert or batch update)
        if not postgres_only:
            if vertex_index_mode.startswith("stream"):
                vector_rows_upserted = _upsert_vertex_vectors(rows, vertex_project, vertex_region, vertex_index_id, vertex_endpoint_id)
            else:
                gcs_bucket = os.environ.get("GCS_BUCKET")
                gcs_prefix = os.environ.get("GCS_PREFIX", "chat_rag_index")
                if not gcs_bucket:
                    raise ValueError(
                        "GCS_BUCKET is required for batch Vertex sync. Set GCS_BUCKET (and optionally GCS_PREFIX) in env. "
                        "Set VERTEX_INDEX_MODE=streaming to use streaming upserts instead."
                    )
                vector_rows_upserted = _update_vertex_batch_index(rows, vertex_project, vertex_region, vertex_index_id, gcs_bucket, gcs_prefix)
        else:
            print("Skipping Vertex update (--postgres-only)", flush=True)

        status = "success"
        # Update watermark so next run is incremental
        max_updated = None
        for row in rows:
            u = row.get("updated_at")
            if u is not None:
                if isinstance(u, datetime):
                    max_updated = u if max_updated is None else max(u, max_updated)
                else:
                    try:
                        dt = datetime.fromisoformat(str(u).replace("Z", "+00:00"))
                        max_updated = dt if max_updated is None else max(dt, max_updated)
                    except (TypeError, ValueError):
                        pass
        if max_updated is not None:
            _write_watermark(bq_client, bq_project, bq_dataset, max_updated)

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
