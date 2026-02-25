#!/usr/bin/env python3
"""
Load NUCC taxonomy CSV to BigQuery landing_medicaid_npi.stg_nucc_taxonomy.
Usage:
  python scripts/load_nucc_to_landing.py [path_to_csv]
  python scripts/load_nucc_to_landing.py                    # uses seeds/nucc_taxonomy_seed.csv
  python scripts/load_nucc_to_landing.py /path/nucc_taxonomy_250.csv

Schema: taxonomy_code STRING, taxonomy_description STRING
NUCC full CSV: map Code->taxonomy_code, use Primary Taxonomy or combined description.
"""

import os
import sys
from pathlib import Path

def main() -> int:
    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    dataset = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")
    table = "stg_nucc_taxonomy"
    table_id = f"{project}.{dataset}.{table}"

    if len(sys.argv) > 1:
        csv_path = Path(sys.argv[1])
    else:
        repo_root = Path(__file__).resolve().parents[1]
        csv_path = repo_root / "seeds" / "nucc_taxonomy_seed.csv"

    if not csv_path.exists():
        print(f"Error: CSV not found: {csv_path}", file=sys.stderr)
        return 1

    try:
        from google.cloud import bigquery
    except ImportError:
        print("Install: pip install google-cloud-bigquery", file=sys.stderr)
        return 1

    client = bigquery.Client(project=project)
    job_config = bigquery.LoadJobConfig(
        schema=[
            bigquery.SchemaField("taxonomy_code", "STRING"),
            bigquery.SchemaField("taxonomy_description", "STRING"),
        ],
        skip_leading_rows=1,
        source_format=bigquery.SourceFormat.CSV,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )

    with open(csv_path, "rb") as f:
        job = client.load_table_from_file(f, table_id, job_config=job_config)

    job.result()
    table_ref = client.get_table(table_id)
    print(f"Loaded {table_ref.num_rows} rows to {table_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
