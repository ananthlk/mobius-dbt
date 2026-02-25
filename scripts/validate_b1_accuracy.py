#!/usr/bin/env python3
"""
B1 accuracy check: sample rows that MATCHED (b1_nppes_pml_mismatch = false)
and rows that MISSED (b1_nppes_pml_mismatch = true) with NPPES vs PML side-by-side.

Run from mobius-dbt with: uv run python scripts/validate_b1_accuracy.py

Uses BigQuery project/dataset from env or defaults (mobius-os-dev, mobius_medicaid_npi_dev).
"""

from __future__ import annotations

import os
import sys


def main() -> None:
    try:
        from google.cloud import bigquery
    except ImportError:
        print("Install google-cloud-bigquery (e.g. uv add google-cloud-bigquery)", file=sys.stderr)
        sys.exit(1)

    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    dataset = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")
    landing = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")
    sample_matched = 5
    sample_missed = 10

    client = bigquery.Client(project=project)

    # Counts
    q_counts = f"""
    SELECT
      COUNTIF(b1_nppes_pml_mismatch = false) AS matched,
      COUNTIF(b1_nppes_pml_mismatch = true)  AS missed,
      COUNT(*) AS total
    FROM `{project}.{dataset}.npi_addresses_fl`
    """
    row = next(client.query(q_counts).result())
    matched_count = row.matched
    missed_count = row.missed
    total = row.total

    print("B1 accuracy check")
    print("=================")
    print(f"Dataset: {project}.{dataset}")
    print(f"Total rows: {total}")
    print(f"B1 pass (matched): {matched_count}")
    print(f"B1 severe (missed): {missed_count}")
    print()

    # PML one row per NPI (latest contract_effective_date), same as npi_addresses_fl
    pml_one = f"""
    ( SELECT npi, address_line_1 AS pml_line_1, city AS pml_city, state AS pml_state, zip AS pml_zip
      FROM `{project}.{landing}.stg_pml`
      WHERE npi IS NOT NULL
      QUALIFY ROW_NUMBER() OVER (PARTITION BY CAST(npi AS STRING) ORDER BY contract_effective_date DESC NULLS LAST) = 1
    )
    """
    # Matched sample: join to PML for side-by-side
    q_matched = f"""
    SELECT
      a.npi,
      a.practice_line_1,
      a.practice_city,
      a.practice_state,
      a.practice_zip,
      a.b1_street_warning,
      p.pml_line_1,
      p.pml_city,
      p.pml_state,
      p.pml_zip
    FROM `{project}.{dataset}.npi_addresses_fl` a
    JOIN {pml_one} p ON CAST(p.npi AS STRING) = CAST(a.npi AS STRING)
    WHERE a.b1_nppes_pml_mismatch = false
    QUALIFY ROW_NUMBER() OVER (ORDER BY a.npi) <= {sample_matched}
    """
    print("=== MATCHED (B1 pass) — sample ===")
    for r in client.query(q_matched).result():
        print(f"NPI {r.npi}")
        print(f"  NPPES practice: {(r.practice_line_1 or '')[:55]} | {r.practice_city} {r.practice_state} {(r.practice_zip or '')[:10]}")
        print(f"  PML service:    {(r.pml_line_1 or '')[:55]} | {r.pml_city} {r.pml_state} {(str(r.pml_zip or ''))[:10]}")
        print(f"  b1_street_warning: {r.b1_street_warning}")
        print()

    # Missed sample (only when there are any)
    if missed_count == 0:
        print("=== MISSED (B1 severe) — none in this dataset ===")
        print("No rows with b1_nppes_pml_mismatch = true. Logic for 'missed' is validated by the model spec and doc.")
        return

    q_missed = f"""
    SELECT
      a.npi,
      a.practice_line_1,
      a.practice_city,
      a.practice_state,
      a.practice_zip,
      a.b1_street_warning,
      p.pml_line_1,
      p.pml_city,
      p.pml_state,
      p.pml_zip
    FROM `{project}.{dataset}.npi_addresses_fl` a
    LEFT JOIN {pml_one} p ON CAST(p.npi AS STRING) = CAST(a.npi AS STRING)
    WHERE a.b1_nppes_pml_mismatch = true
    QUALIFY ROW_NUMBER() OVER (ORDER BY a.npi) <= {sample_missed}
    """
    print("=== MISSED (B1 severe) — sample ===")
    for r in client.query(q_missed).result():
        print(f"NPI {r.npi}")
        print(f"  NPPES practice: {(r.practice_line_1 or '')[:55]} | {r.practice_city} {r.practice_state} {(r.practice_zip or '')[:10]}")
        print(f"  PML service:    {(r.pml_line_1 or '')[:55] if r.pml_line_1 else 'NULL'} | {r.pml_city or 'NULL'} {r.pml_state or 'NULL'} {str(r.pml_zip or '')[:10]}")
        print(f"  b1_street_warning: {r.b1_street_warning}")
        print()


if __name__ == "__main__":
    main()
