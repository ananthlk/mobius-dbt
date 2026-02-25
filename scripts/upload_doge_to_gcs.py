#!/usr/bin/env python3
"""
Upload local DOGE Medicaid CSV to GCS.
Usage:
  python upload_doge_to_gcs.py /path/to/doge.csv
  DOGE_LOCAL_PATH=/path/to/doge.csv python upload_doge_to_gcs.py

Expects CSV with header: npi,billing_tin,servicing_tin,hcpcs_code,period_month,beneficiary_count,claim_count,total_paid,state
"""
import os
import sys
from datetime import datetime
from pathlib import Path

PROJECT = os.environ.get("BQ_PROJECT", "mobius-os-dev")
BUCKET = os.environ.get("GCS_MEDICAID_BUCKET", f"{PROJECT}-fl-medicaid-npi-raw")


def main():
    local_path = os.environ.get("DOGE_LOCAL_PATH") or (sys.argv[1] if len(sys.argv) > 1 else None)
    if not local_path:
        print("Usage: python upload_doge_to_gcs.py /path/to/doge.csv", file=sys.stderr)
        print("   or: DOGE_LOCAL_PATH=/path/to/doge.csv python upload_doge_to_gcs.py", file=sys.stderr)
        sys.exit(1)

    path = Path(local_path)
    if not path.exists():
        print(f"File not found: {path}", file=sys.stderr)
        sys.exit(1)

    from google.cloud import storage

    today = datetime.now().strftime("%Y-%m-%d")
    blob_path = f"raw/doge/{today}/doge.csv"
    client = storage.Client(project=PROJECT)
    bucket = client.bucket(BUCKET)
    blob = bucket.blob(blob_path)
    blob.upload_from_filename(str(path), content_type="text/csv")
    gcs_uri = f"gs://{BUCKET}/{blob_path}"
    print(f"Uploaded {path} to {gcs_uri}")
    print(f"  Next: run load_medicaid_from_gcs.py (or set DOGE_GCS_URI={gcs_uri})")


if __name__ == "__main__":
    main()
