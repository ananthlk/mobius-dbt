#!/usr/bin/env python3
"""
Load Medicaid landing tables from GCS into BigQuery.
- DOGE: from gs://bucket/raw/doge/ (use DOGE_GCS_URI for specific file, or auto-detect latest)
- TML, PML: use seed_medicaid_from_bq.py (sourced from NPPES); this script loads DOGE only.

Env: BQ_PROJECT, GCS_MEDICAID_BUCKET, DOGE_GCS_URI (optional)
"""
import os

PROJECT = os.environ.get("BQ_PROJECT", "mobius-os-dev")
BUCKET = os.environ.get("GCS_MEDICAID_BUCKET") or f"{PROJECT}-fl-medicaid-npi-raw"
LANDING = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")


def _find_latest_doge_uri():
    """Find latest DOGE CSV under gs://bucket/raw/doge/."""
    from google.cloud import storage

    client = storage.Client(project=PROJECT)
    bucket = client.bucket(BUCKET)
    blobs = list(bucket.list_blobs(prefix="raw/doge/", max_results=500))
    csv_blobs = [b for b in blobs if b.name.endswith(".csv")]
    if not csv_blobs:
        return None
    # Sort by updated time, newest first
    csv_blobs.sort(key=lambda b: b.updated or b.time_created, reverse=True)
    return f"gs://{BUCKET}/{csv_blobs[0].name}"


def load_doge(gcs_uri=None):
    """Load DOGE CSV from GCS into BigQuery landing."""
    from google.cloud import bigquery

    uri = gcs_uri or os.environ.get("DOGE_GCS_URI") or _find_latest_doge_uri()
    if not uri:
        print("  No DOGE file in GCS. Upload first: DOGE_LOCAL_PATH=... python upload_doge_to_gcs.py")
        return

    client = bigquery.Client(project=PROJECT)
    table_id = f"{PROJECT}.{LANDING}.stg_doge"

    job_config = bigquery.LoadJobConfig(
        schema=[
            bigquery.SchemaField("npi", "STRING"),
            bigquery.SchemaField("billing_tin", "STRING"),
            bigquery.SchemaField("servicing_tin", "STRING"),
            bigquery.SchemaField("hcpcs_code", "STRING"),
            bigquery.SchemaField("period_month", "STRING"),  # YYYY-MM format from HHS
            bigquery.SchemaField("beneficiary_count", "INT64"),
            bigquery.SchemaField("claim_count", "INT64"),
            bigquery.SchemaField("total_paid", "FLOAT64"),
            bigquery.SchemaField("state", "STRING"),
        ],
        skip_leading_rows=1,
        source_format=bigquery.SourceFormat.CSV,
        autodetect=False,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )

    print(f"  Loading DOGE from {uri} into {table_id}...")
    job = client.load_table_from_uri(uri, table_id, job_config=job_config)
    job.result()
    table = client.get_table(table_id)
    print(f"  Loaded {table.num_rows:,} rows into {table_id}")


def main():
    print("=== Load Medicaid from GCS ===")
    print(f"  BQ_PROJECT={PROJECT}")
    print(f"  GCS_MEDICAID_BUCKET={BUCKET}")
    load_doge()
    print("Done.")


if __name__ == "__main__":
    main()
