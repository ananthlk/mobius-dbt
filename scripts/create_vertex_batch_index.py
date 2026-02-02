#!/usr/bin/env python3
"""
Create or update a Vertex AI Vector Search BATCH index from the BigQuery mart.
Use this when you want a batch index (no streaming upserts) for Chat dev.
Batch indexes: export mart → GCS (JSON) → create/update index. Rebuild on each sync.

Env (required):
  BQ_PROJECT, BQ_DATASET (mart location)
  GCS_BUCKET (bucket for index data, e.g. mobiusos-new-vertex-index)
  VERTEX_PROJECT, VERTEX_REGION

Env (optional):
  VERTEX_INDEX_ID (existing batch index to update; omit to create new)
  VERTEX_INDEX_DISPLAY_NAME (display name for new index; default: mobius_chat_published_rag)
  GCS_PREFIX (prefix under bucket; default: chat_rag_index)

Usage:
  # Create new batch index (first run)
  python scripts/create_vertex_batch_index.py

  # Update existing batch index (subsequent syncs)
  VERTEX_INDEX_ID=1234567890 python scripts/create_vertex_batch_index.py
"""

import json
import os
import sys
import tempfile
from typing import Any, Dict, List, Optional

try:
    from google.cloud import bigquery
except ImportError:
    print("Install google-cloud-bigquery: pip install google-cloud-bigquery", file=sys.stderr)
    sys.exit(1)

try:
    from google.cloud import storage
except ImportError:
    print("Install google-cloud-storage: pip install google-cloud-storage", file=sys.stderr)
    sys.exit(1)

try:
    from google.cloud import aiplatform
except ImportError:
    print("Install google-cloud-aiplatform: pip install google-cloud-aiplatform", file=sys.stderr)
    sys.exit(1)


DIMENSIONS = 1536
DISTANCE = "COSINE_DISTANCE"  # or DOT_PRODUCT_DISTANCE; align with RAG
DISPLAY_NAME = "mobius_chat_published_rag"


def _read_mart(bq_client: bigquery.Client, project: str, dataset: str) -> List[Dict[str, Any]]:
    """Read all rows from BigQuery mart."""
    table_id = f"{project}.{dataset}.published_rag_embeddings"
    print(f"Reading mart: {table_id}...", flush=True)
    rows = []
    for row in bq_client.query(f"SELECT * FROM `{table_id}`").result():
        rows.append(dict(row))
    print(f"Read {len(rows)} rows.", flush=True)
    return rows


def _row_to_vertex_json(row: Dict[str, Any]) -> Optional[str]:
    """Convert mart row to Vertex batch JSON line (id, embedding, restricts)."""
    emb = row.get("embedding")
    if not emb or not isinstance(emb, list) or len(emb) != DIMENSIONS:
        return None
    restricts = [
        {"namespace": "document_payer", "allow": [str(row.get("document_payer") or "")]},
        {"namespace": "document_state", "allow": [str(row.get("document_state") or "")]},
        {"namespace": "document_program", "allow": [str(row.get("document_program") or "")]},
        {"namespace": "document_authority_level", "allow": [str(row.get("document_authority_level") or "")]},
        {"namespace": "source_type", "allow": [str(row.get("source_type") or "")]},
    ]
    rec = {
        "id": str(row.get("id")),
        "embedding": [float(x) for x in emb],
        "restricts": restricts,
        "crowding_tag": str(row.get("document_id") or ""),
    }
    return json.dumps(rec)


def _export_to_gcs(rows: List[Dict[str, Any]], bucket_name: str, prefix: str, project: str) -> str:
    """Export mart rows to GCS as JSON lines. Returns gs://bucket/prefix URI."""
    print(f"Exporting to gs://{bucket_name}/{prefix}...", flush=True)
    client = storage.Client(project=project)
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(f"{prefix}/data.json")
    lines = []
    for row in rows:
        line = _row_to_vertex_json(row)
        if line:
            lines.append(line)
    content = "\n".join(lines)
    blob.upload_from_string(content, content_type="application/json")
    gcs_uri = f"gs://{bucket_name}/{prefix}"
    print(f"Exported {len(lines)} records to {gcs_uri}", flush=True)
    return gcs_uri


def _create_batch_index(
    project: str, region: str, gcs_uri: str, display_name: str
) -> str:
    """Create new batch index. Returns index resource name."""
    print(f"Creating batch index '{display_name}' from {gcs_uri}...", flush=True)
    aiplatform.init(project=project, location=region)
    index = aiplatform.MatchingEngineIndex.create_tree_ah_index(
        display_name=display_name,
        contents_delta_uri=gcs_uri,
        description="Published RAG embeddings (batch) for Mobius Chat",
        dimensions=DIMENSIONS,
        approximate_neighbors_count=150,
        leaf_node_embedding_count=500,
        leaf_nodes_to_search_percent=7,
        index_update_method="BATCH_UPDATE",
        distance_measure_type=aiplatform.matching_engine.matching_engine_index_config.DistanceMeasureType.COSINE_DISTANCE,
    )
    idx_name = index.resource_name
    print(f"Index creation started. Resource: {idx_name}", flush=True)
    print("Note: Index build can take 30-60+ minutes. Deploy to endpoint when ready.", flush=True)
    return idx_name


def _update_batch_index(project: str, region: str, index_id: str, gcs_uri: str) -> None:
    """Update existing batch index with new GCS data (full overwrite)."""
    print(f"Updating batch index {index_id} with {gcs_uri}...", flush=True)
    aiplatform.init(project=project, location=region)
    index = aiplatform.MatchingEngineIndex(index_name=index_id)
    index.update_embeddings(
        contents_delta_uri=gcs_uri,
        is_complete_overwrite=True,
    )
    print("Index update started. Deployment will sync when build completes.", flush=True)


def main() -> int:
    bq_project = os.environ.get("BQ_PROJECT")
    bq_dataset = os.environ.get("BQ_DATASET")
    gcs_bucket = os.environ.get("GCS_BUCKET")
    vertex_project = os.environ.get("VERTEX_PROJECT")
    vertex_region = os.environ.get("VERTEX_REGION")
    vertex_index_id = os.environ.get("VERTEX_INDEX_ID")
    display_name = os.environ.get("VERTEX_INDEX_DISPLAY_NAME", DISPLAY_NAME)
    gcs_prefix = os.environ.get("GCS_PREFIX", "chat_rag_index")

    if not all([bq_project, bq_dataset, gcs_bucket, vertex_project, vertex_region]):
        print("Set: BQ_PROJECT, BQ_DATASET, GCS_BUCKET, VERTEX_PROJECT, VERTEX_REGION", file=sys.stderr)
        return 1

    bq_client = bigquery.Client(project=bq_project)
    rows = _read_mart(bq_client, bq_project, bq_dataset)
    if not rows:
        print("No rows in mart; nothing to export.", flush=True)
        return 0

    gcs_uri = _export_to_gcs(rows, gcs_bucket, gcs_prefix, vertex_project)

    if vertex_index_id:
        _update_batch_index(vertex_project, vertex_region, vertex_index_id, gcs_uri)
    else:
        _create_batch_index(vertex_project, vertex_region, gcs_uri, display_name)

    return 0


if __name__ == "__main__":
    sys.exit(main())
