#!/usr/bin/env python3
"""
Extract DOGE Medicaid data, (optionally) TML/PML samples, upload to GCS, load to BigQuery.
DOGE: from Hugging Face HHS-Official/medicaid-provider-spending (filter sample for dev).
TML/PML: require manual upload from FL Medicaid portal; use seed data if provided.
"""
import os
import csv
import tempfile
from datetime import datetime
from pathlib import Path

PROJECT = os.environ.get("BQ_PROJECT", "mobius-os-dev")
BUCKET = os.environ.get("GCS_MEDICAID_BUCKET", f"{PROJECT}-fl-medicaid-npi-raw")
# Set DOGE_SAMPLE_ROWS to limit (e.g. 500000); unset or 0 = no limit (load full 227M)
SAMPLE_ROWS = int(os.environ.get("DOGE_SAMPLE_ROWS", "0") or "0")


def extract_doge_to_gcs():
    """Extract DOGE from Hugging Face, write CSV to GCS, return local path for load."""
    from google.cloud import storage

    print("Loading DOGE dataset from Hugging Face (sample)...")
    try:
        from datasets import load_dataset
    except ImportError:
        print("  pip install datasets")
        raise

    # Use streaming to avoid loading full 227M rows
    ds = load_dataset(
        "HHS-Official/medicaid-provider-spending",
        split="train",
        streaming=True,
    )
    def _get(d, *keys):
        for k in keys:
            if k in d:
                return d[k]
        low = {str(kk).lower(): v for kk, v in d.items()}
        for k in keys:
            if str(k).lower() in low:
                return low[str(k).lower()]
        return None

    today = datetime.now().strftime("%Y-%m-%d")
    local_dir = Path(tempfile.mkdtemp())
    csv_path = local_dir / "doge_sample.csv"

    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = None
        for i, row in enumerate(ds):
            if SAMPLE_ROWS and i >= SAMPLE_ROWS:
                break
            d = dict(row)
            npi = str(_get(d, "BILLING_PROVIDER_NPI_NUM", "billing_provider_npi_num") or "")
            billing_tin = str(_get(d, "BILLING_PROVIDER_TIN", "billing_tin") or "")
            servicing_tin = str(_get(d, "SERVICING_PROVIDER_TIN", "servicing_tin") or "")
            hcpcs = str(_get(d, "HCPCS_CODE", "hcpcs_code") or "")
            month = str(_get(d, "CLAIM_FROM_MONTH", "claim_from_month") or "")
            benes = _get(d, "TOTAL_UNIQUE_BENEFICIARIES", "total_unique_beneficiaries") or 0
            claims = _get(d, "TOTAL_CLAIMS", "total_claims") or 0
            paid = float(_get(d, "TOTAL_PAID", "total_paid") or 0)
            state = str(_get(d, "STATE_CD", "state") or "")

            out = {
                "npi": npi,
                "billing_tin": billing_tin,
                "servicing_tin": servicing_tin,
                "hcpcs_code": hcpcs,
                "period_month": (month[:7] + "-01") if month and len(month) >= 7 else "1900-01-01",
                "beneficiary_count": benes,
                "claim_count": claims,
                "total_paid": paid,
                "state": state,
            }
            if writer is None:
                writer = csv.DictWriter(f, fieldnames=list(out.keys()))
                writer.writeheader()
            writer.writerow(out)
        if writer is None:
            print("  No rows; writing empty CSV with header")
            writer = csv.DictWriter(
                f,
                fieldnames=["npi", "billing_tin", "servicing_tin", "hcpcs_code", "period_month", "beneficiary_count", "claim_count", "total_paid", "state"],
            )
            writer.writeheader()

    print(f"  Wrote {csv_path.stat().st_size / 1024 / 1024:.1f} MB to {csv_path}")

    # Upload to GCS
    client = storage.Client(project=PROJECT)
    bucket = client.bucket(BUCKET)
    blob_path = f"raw/doge/{today}/doge_sample.csv"
    blob = bucket.blob(blob_path)
    blob.upload_from_filename(str(csv_path), content_type="text/csv")
    print(f"  Uploaded to gs://{BUCKET}/{blob_path}")

    return f"gs://{BUCKET}/{blob_path}"


def load_doge_from_gcs(gcs_uri: str):
    """Load DOGE CSV from GCS into BigQuery landing."""
    from google.cloud import bigquery

    client = bigquery.Client(project=PROJECT)
    table_id = f"{PROJECT}.landing_medicaid_npi_dev.stg_doge"

    job_config = bigquery.LoadJobConfig(
        schema=[
            bigquery.SchemaField("npi", "STRING"),
            bigquery.SchemaField("billing_tin", "STRING"),
            bigquery.SchemaField("servicing_tin", "STRING"),
            bigquery.SchemaField("hcpcs_code", "STRING"),
            bigquery.SchemaField("period_month", "DATE"),
            bigquery.SchemaField("beneficiary_count", "INT64"),
            bigquery.SchemaField("claim_count", "INT64"),
            bigquery.SchemaField("total_paid", "FLOAT64"),
            bigquery.SchemaField("state", "STRING"),
        ],
        skip_leading_rows=1,
        source_format=bigquery.SourceFormat.CSV,
        autodetect=False,
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
    )

    job = client.load_table_from_uri(gcs_uri, table_id, job_config=job_config)
    job.result()
    table = client.get_table(table_id)
    print(f"  Loaded {table.num_rows} rows into {table_id}")


def seed_tml_from_nppes():
    """Seed TML from NPPES healthcare_provider_taxonomy_code_set (taxonomy reference)."""
    from google.cloud import bigquery, storage

    client = bigquery.Client(project=PROJECT)
    # NPPES has healthcare_provider_taxonomy_code_set_* - pick one
    query = """
    SELECT
      code AS taxonomy_code,
      COALESCE(definition, grouping || ' - ' || classification) AS taxonomy_description,
      grouping AS provider_type,
      CAST(NULL AS INT64) AS provider_type_number,
      specialization AS specialty_type,
      CAST(NULL AS INT64) AS specialty_type_number
    FROM `bigquery-public-data.nppes.healthcare_provider_taxonomy_code_set_120`
    LIMIT 5000
    """
    try:
        rows = list(client.query(query).result())
    except Exception as e:
        print(f"  TML seed from NPPES failed: {e}")
        return None

    today = datetime.now().strftime("%Y-%m-%d")
    local_path = Path(tempfile.mkdtemp()) / "tml_seed.csv"
    with open(local_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(
            f,
            fieldnames=["taxonomy_code", "taxonomy_description", "provider_type", "provider_type_number", "specialty_type", "specialty_type_number"],
        )
        w.writeheader()
        for r in rows:
            w.writerow({
                "taxonomy_code": r.taxonomy_code or "",
                "taxonomy_description": r.taxonomy_description or "",
                "provider_type": "",
                "provider_type_number": "",
                "specialty_type": "",
                "specialty_type_number": "",
            })

    blob_path = f"raw/tml/{today}/tml_seed.csv"
    storage.Client(project=PROJECT).bucket(BUCKET).blob(blob_path).upload_from_filename(str(local_path), content_type="text/csv")
    print(f"  Uploaded TML seed to gs://{BUCKET}/{blob_path}")

    # Load to BQ
    table_id = f"{PROJECT}.landing_medicaid_npi_dev.stg_tml"
    config = bigquery.LoadJobConfig(
        schema=[
            bigquery.SchemaField("taxonomy_code", "STRING"),
            bigquery.SchemaField("taxonomy_description", "STRING"),
            bigquery.SchemaField("provider_type", "STRING"),
            bigquery.SchemaField("provider_type_number", "INT64"),
            bigquery.SchemaField("specialty_type", "STRING"),
            bigquery.SchemaField("specialty_type_number", "INT64"),
        ],
        skip_leading_rows=1,
        source_format=bigquery.SourceFormat.CSV,
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
    )
    client.load_table_from_uri(f"gs://{BUCKET}/{blob_path}", table_id, job_config=config).result()
    print(f"  Loaded TML seed into {table_id}")


def main():
    print("=== 1. DOGE extract + upload + load ===")
    try:
        gcs_uri = extract_doge_to_gcs()
        load_doge_from_gcs(gcs_uri)
    except Exception as e:
        print(f"DOGE failed: {e}")
        raise

    print("\n=== 2. TML seed from NPPES taxonomy ===")
    try:
        seed_tml_from_nppes()
    except Exception as e:
        print(f"TML seed failed (non-fatal): {e}")

    print("\n=== 3. PML ===")
    print("  PML requires manual download from FL Medicaid portal. Upload CSV to gs://{}/raw/pml/<date>/ and run load_medicaid_from_gcs.py".format(BUCKET))

    print("\nDone.")


if __name__ == "__main__":
    main()
