#!/usr/bin/env python3
"""
Load NUCC taxonomy CSV to BigQuery landing_medicaid_npi.stg_nucc_taxonomy.

Usage:
  python scripts/load_nucc_to_landing.py [path_to_csv]
  python scripts/load_nucc_to_landing.py                    # uses seeds/nucc_taxonomy_seed.csv (～46 codes)
  python scripts/load_nucc_to_landing.py /path/nucc_taxonomy_251.csv   # full NUCC (800+ codes)

Accepts:
  - Our seed format: header taxonomy_code, taxonomy_description
  - Official NUCC CSV: header Code, Definition (other columns ignored)

Schema: taxonomy_code STRING, taxonomy_description STRING
One row per code; duplicates by code are dropped (first wins).
"""

import csv
import io
import os
import sys
from pathlib import Path

# Column mapping: (code_key, desc_key) for CSV header detection (case-insensitive)
CODE_ALIASES = ("taxonomy_code", "code")
DESC_ALIASES = ("taxonomy_description", "definition", "description")


def _normalize_header(name: str) -> str:
    return (name or "").strip().lower()


def _find_columns(headers: list[str]) -> tuple[int, int] | None:
    norm = [_normalize_header(h) for h in headers]
    code_idx = None
    desc_idx = None
    for i, h in enumerate(norm):
        if h in CODE_ALIASES:
            code_idx = i
        if h in DESC_ALIASES:
            desc_idx = i
    if code_idx is not None and desc_idx is not None:
        return (code_idx, desc_idx)
    return None


def read_and_normalize(csv_path: Path) -> list[tuple[str, str]]:
    """Read CSV and return list of (taxonomy_code, taxonomy_description), deduped by code."""
    rows: list[tuple[str, str]] = []
    seen: set[str] = set()
    with open(csv_path, newline="", encoding="utf-8", errors="replace") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        if not header:
            return rows
        cols = _find_columns(header)
        if cols is None:
            raise ValueError(
                f"CSV must have columns for code and description. "
                f"Expected one of {CODE_ALIASES} and one of {DESC_ALIASES}. Got: {header}"
            )
        code_idx, desc_idx = cols
        for row in reader:
            if len(row) <= max(code_idx, desc_idx):
                continue
            code = (row[code_idx] or "").strip()
            desc = (row[desc_idx] or "").strip()
            if not code:
                continue
            if code in seen:
                continue
            seen.add(code)
            rows.append((code, desc))
    return rows


def main() -> int:
    # Medicaid NPI landing in Mobius-OS-Dev
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
        rows = read_and_normalize(csv_path)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    if not rows:
        print("Error: No rows to load.", file=sys.stderr)
        return 1

    # Build CSV in memory with our schema for BQ load
    buf = io.BytesIO()
    writer = csv.writer(io.TextIOWrapper(buf, encoding="utf-8", newline=""))
    writer.writerow(["taxonomy_code", "taxonomy_description"])
    writer.writerows(rows)
    buf.seek(0)
    # Re-open as bytes for load_table_from_file (BQ expects bytes)
    buf = io.BytesIO(buf.getvalue())

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

    job = client.load_table_from_file(buf, table_id, job_config=job_config)
    job.result()
    table_ref = client.get_table(table_id)
    print(f"Loaded {table_ref.num_rows} rows to {table_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
