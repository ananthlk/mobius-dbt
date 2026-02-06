#!/usr/bin/env python3
"""
Create a Vertex AI Vector Search STREAM_UPDATE index from the BigQuery mart.

Why:
- Streaming index supports incremental updates via upsertDatapoints (no batch overwrite).
- You cannot convert an existing BATCH_UPDATE index to STREAM_UPDATE; you must create a new index.

Env (required):
  BQ_PROJECT, BQ_DATASET           (mart location)
  GCS_BUCKET                      (bucket for initial index content export)
  VERTEX_PROJECT, VERTEX_REGION

Env (optional):
  VERTEX_INDEX_DISPLAY_NAME       (default: mobius-chat-streaming-index)
  GCS_PREFIX                      (default: chat_rag_index_streaming_init)
"""

import json
import os
import sys
from typing import Any, Dict, List, Optional

from google.cloud import bigquery
from google.cloud import storage
from google.cloud import aiplatform


DIMENSIONS = 1536
DEFAULT_DISPLAY_NAME = "mobius-chat-streaming-index"


def _read_mart(bq_client: bigquery.Client, project: str, dataset: str) -> List[Dict[str, Any]]:
    table_id = f"{project}.{dataset}.published_rag_embeddings"
    print(f"Reading mart: {table_id}...", flush=True)
    rows: List[Dict[str, Any]] = []
    for row in bq_client.query(f"SELECT * FROM `{table_id}`").result():
        rows.append(dict(row))
    print(f"Read {len(rows)} rows.", flush=True)
    return rows


def _row_to_vertex_json(row: Dict[str, Any]) -> Optional[str]:
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
    print(f"Exporting initial data to gs://{bucket_name}/{prefix}...", flush=True)
    client = storage.Client(project=project)
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(f"{prefix}/data.json")
    lines: List[str] = []
    for row in rows:
        line = _row_to_vertex_json(row)
        if line:
            lines.append(line)
    blob.upload_from_string("\n".join(lines), content_type="application/json")
    gcs_uri = f"gs://{bucket_name}/{prefix}"
    print(f"Exported {len(lines)} records to {gcs_uri}", flush=True)
    return gcs_uri


def main() -> int:
    bq_project = os.environ.get("BQ_PROJECT")
    bq_dataset = os.environ.get("BQ_DATASET")
    gcs_bucket = os.environ.get("GCS_BUCKET")
    vertex_project = os.environ.get("VERTEX_PROJECT")
    vertex_region = os.environ.get("VERTEX_REGION")
    display_name = os.environ.get("VERTEX_INDEX_DISPLAY_NAME", DEFAULT_DISPLAY_NAME)
    gcs_prefix = os.environ.get("GCS_PREFIX", "chat_rag_index_streaming_init")

    if not all([bq_project, bq_dataset, gcs_bucket, vertex_project, vertex_region]):
        print("Set: BQ_PROJECT, BQ_DATASET, GCS_BUCKET, VERTEX_PROJECT, VERTEX_REGION", file=sys.stderr)
        return 1

    bq_client = bigquery.Client(project=bq_project)
    rows = _read_mart(bq_client, bq_project, bq_dataset)
    if not rows:
        print("No rows in mart; refusing to create empty streaming index from mart.", file=sys.stderr)
        return 1

    gcs_uri = _export_to_gcs(rows, gcs_bucket, gcs_prefix, vertex_project)

    print(f"Creating STREAM_UPDATE index '{display_name}' in {vertex_project}/{vertex_region}...", flush=True)
    aiplatform.init(project=vertex_project, location=vertex_region)
    idx = aiplatform.MatchingEngineIndex.create_tree_ah_index(
        display_name=display_name,
        contents_delta_uri=gcs_uri,
        description="Published RAG embeddings (streaming) for Mobius Chat",
        dimensions=DIMENSIONS,
        approximate_neighbors_count=150,
        leaf_node_embedding_count=500,
        leaf_nodes_to_search_percent=7,
        index_update_method="STREAM_UPDATE",
        distance_measure_type=aiplatform.matching_engine.matching_engine_index_config.DistanceMeasureType.COSINE_DISTANCE,
    )
    print(f"CreateIndex started. Resource name: {idx.resource_name}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

