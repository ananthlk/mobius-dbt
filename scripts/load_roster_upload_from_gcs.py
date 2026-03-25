#!/usr/bin/env python3
"""Load roster resolved CSV from GCS to BigQuery stg_roster_upload.

Usage:
  BQ_PROJECT=mobius-os-dev BQ_LANDING_MEDICAID_DATASET=landing_medicaid_npi_dev \\
  uv run python scripts/load_roster_upload_from_gcs.py <upload_id>

Reads gs://{bucket}/cleansed/roster_uploads/{upload_id}/roster_resolved.csv
and loads into {dataset}.stg_roster_upload (truncate + load for that upload_id).
"""
import os
import sys
from pathlib import Path

# Add repo root for imports
REPO = Path(__file__).resolve().parent.parent
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

def main():
    upload_id = (sys.argv[1] or "").strip()
    if not upload_id:
        print("Usage: load_roster_upload_from_gcs.py <upload_id>", file=sys.stderr)
        sys.exit(1)

    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    dataset = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")
    bucket_name = os.environ.get("GCS_ROSTER_BUCKET") or f"{project}-fl-medicaid-npi-raw"
    gcs_uri = f"gs://{bucket_name}/cleansed/roster_uploads/{upload_id}/roster_resolved.csv"

    try:
        from google.cloud import bigquery
        client = bigquery.Client(project=project)
        table_id = f"{project}.{dataset}.stg_roster_upload"

        # Delete existing rows for this upload_id (skip if table doesn't exist)
        try:
            client.query(
                f"DELETE FROM `{table_id}` WHERE upload_id = @upload_id",
                job_config=bigquery.QueryJobConfig(
                    query_parameters=[bigquery.ScalarQueryParameter("upload_id", "STRING", upload_id)]
                ),
            ).result()
        except Exception as e:
            if "Not found" not in str(e) and "404" not in str(e):
                raise

        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.CSV,
            skip_leading_rows=1,
            autodetect=True,
            write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
            create_disposition=bigquery.CreateDisposition.CREATE_IF_NEEDED,
        )

        load_job = client.load_table_from_uri(gcs_uri, table_id, job_config=job_config)
        load_job.result()
        print(f"Loaded {load_job.output_rows} rows from {gcs_uri} to {table_id}")
    except Exception as e:
        print(f"Load failed: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
