#!/usr/bin/env python3
"""
Export 50 MATCHED (B1 pass) and 50 MISMATCHED (B1 severe) samples from the table
where B1 outputs are used: provider_readiness_report + npi_addresses_fl + PML.
Includes severity (status_flag, readiness_score), issue flags (issue_b1, issue_b2, issue_b3),
and NPPES vs PML addresses for validation.

Run from mobius-dbt: uv run python scripts/sample_b1_match_mismatch.py
Output: reports/b1_sample_matched.csv and reports/b1_sample_mismatched.csv (and a short console summary).
"""

from __future__ import annotations

import csv
import os
import sys
from pathlib import Path


def main() -> None:
    try:
        from google.cloud import bigquery
    except ImportError:
        print("Install google-cloud-bigquery (e.g. uv add google-cloud-bigquery)", file=sys.stderr)
        sys.exit(1)

    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    dataset = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")
    landing = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")
    n_sample = 50

    client = bigquery.Client(project=project)
    reports_dir = Path(__file__).resolve().parent.parent / "reports"
    reports_dir.mkdir(exist_ok=True)

    # PML one row per NPI (same as npi_addresses_fl)
    pml_cte = f"""
    ( SELECT CAST(npi AS STRING) AS npi, address_line_1 AS pml_line_1, city AS pml_city, state AS pml_state, zip AS pml_zip, zip_plus_4 AS pml_zip_plus_4
      FROM `{project}.{landing}.stg_pml`
      WHERE npi IS NOT NULL
      QUALIFY ROW_NUMBER() OVER (PARTITION BY CAST(npi AS STRING) ORDER BY contract_effective_date DESC NULLS LAST) = 1
    )
    """

    # Columns: report (severity) + B1 sub-flags/status from npi_addresses_fl + addresses
    sel = """
    r.report_date,
    r.billing_npi,
    r.servicing_npi,
    r.billing_org_name,
    r.status_flag,
    r.readiness_score,
    r.issue_b1,
    r.issue_b2,
    r.issue_b3,
    r.servicing_provider_name,
    a.b1_status,
    a.b1_nppes_pml_mismatch,
    a.b1_nppes_practice_line1_present,
    a.b1_pml_line1_present,
    a.b1_nppes_zip9_present,
    a.b1_pml_zip9_present,
    a.b1_zip9_match,
    a.b1_city_match,
    a.b1_state_match,
    a.b1_nppes_zip9,
    a.b1_pml_zip9,
    a.b1_street_warning,
    a.practice_line_1   AS nppes_practice_line_1,
    a.practice_city     AS nppes_city,
    a.practice_state    AS nppes_state,
    a.practice_zip      AS nppes_zip,
    p.pml_line_1,
    p.pml_city          AS pml_city,
    p.pml_state         AS pml_state,
    p.pml_zip           AS pml_zip,
    p.pml_zip_plus_4    AS pml_zip_plus_4
    """

    # 50 MATCHED (issue_b1 = false)
    q_matched = f"""
    WITH pml_one AS {pml_cte}
    SELECT {sel}
    FROM `{project}.{dataset}.provider_readiness_report` r
    JOIN `{project}.{dataset}.npi_addresses_fl` a ON CAST(a.npi AS STRING) = CAST(r.servicing_npi AS STRING)
    LEFT JOIN pml_one p ON p.npi = CAST(r.servicing_npi AS STRING)
    WHERE r.issue_b1 = false
    QUALIFY ROW_NUMBER() OVER (ORDER BY r.report_date DESC, r.billing_npi, r.servicing_npi) <= {n_sample}
    """
    rows_matched = list(client.query(q_matched).result())

    # 50 MISMATCHED (issue_b1 = true)
    q_mismatched = f"""
    WITH pml_one AS {pml_cte}
    SELECT {sel}
    FROM `{project}.{dataset}.provider_readiness_report` r
    JOIN `{project}.{dataset}.npi_addresses_fl` a ON CAST(a.npi AS STRING) = CAST(r.servicing_npi AS STRING)
    LEFT JOIN pml_one p ON p.npi = CAST(r.servicing_npi AS STRING)
    WHERE r.issue_b1 = true
    QUALIFY ROW_NUMBER() OVER (ORDER BY r.report_date DESC, r.billing_npi, r.servicing_npi) <= {n_sample}
    """
    rows_mismatched = list(client.query(q_mismatched).result())

    # Field names from first row (BigQuery Row keys)
    def row_to_dict(r):
        return dict(r.items())

    cols = list(rows_matched[0].keys()) if rows_matched else list(rows_mismatched[0].keys()) if rows_mismatched else []

    out_matched = reports_dir / "b1_sample_matched.csv"
    out_mismatched = reports_dir / "b1_sample_mismatched.csv"

    for out_path, rows in [(out_matched, rows_matched), (out_mismatched, rows_mismatched)]:
        with open(out_path, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
            w.writeheader()
            for r in rows:
                w.writerow({k: ("" if v is None else str(v)) for k, v in row_to_dict(r).items()})

    # Console summary
    print("B1 sample export (report table + B1 outputs + addresses)")
    print("======================================================")
    print(f"Dataset: {project}.{dataset}")
    print(f"Matched (issue_b1=false): {len(rows_matched)} rows -> {out_matched}")
    print(f"Mismatched (issue_b1=true): {len(rows_mismatched)} rows -> {out_mismatched}")
    print()
    if rows_matched:
        r = rows_matched[0]
        print("Matched sample (first row):")
        print(f"  b1_status={r.b1_status} issue_b1={r.issue_b1}")
        print(f"  b1_zip9_match={r.b1_zip9_match}")
        print(f"  NPPES: {(r.nppes_practice_line_1 or '')[:50]} | {r.nppes_city} {r.nppes_state} {r.nppes_zip} (zip9={r.b1_nppes_zip9})")
        print(f"  PML:   {(r.pml_line_1 or '')[:50]} | {r.pml_city} {r.pml_state} {r.pml_zip} (zip9={r.b1_pml_zip9})")
    print()
    if rows_mismatched:
        r = rows_mismatched[0]
        print("Mismatched sample (first row):")
        print(f"  b1_status={r.b1_status} issue_b1={r.issue_b1}")
        print(f"  b1_zip9_match={r.b1_zip9_match}")
        print(f"  NPPES: {(r.nppes_practice_line_1 or '')[:50]} | {r.nppes_city} {r.nppes_state} {r.nppes_zip} (zip9={r.b1_nppes_zip9})")
        print(f"  PML:   {(r.pml_line_1 or '')[:50]} | {r.pml_city} {r.pml_state} {r.pml_zip} (zip9={r.b1_pml_zip9})")


if __name__ == "__main__":
    main()
