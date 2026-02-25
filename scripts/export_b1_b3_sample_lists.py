#!/usr/bin/env python3
"""
Export sample lists: 25 no issues, 25 B1 only, 25 B3 only, few with both.
Joins npi_addresses_fl (B1) and b3_taxonomy_alignment_fl (B3 taxonomy) on npi.
Output: reports/b1_b3_samples_no_issues.csv, _b1_only.csv, _b3_only.csv, _both.csv
"""

from __future__ import annotations

import csv
import os
from pathlib import Path


def main() -> None:
    try:
        from google.cloud import bigquery
    except ImportError:
        print("Install google-cloud-bigquery", file=__import__("sys").stderr)
        raise SystemExit(1)

    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    dataset = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")
    client = bigquery.Client(project=project)
    reports_dir = Path(__file__).resolve().parent.parent / "reports"
    reports_dir.mkdir(exist_ok=True)

    # Join B1 and B3 taxonomy; one row per npi with both flags
    base = f"""
    with j as (
      select
        a.npi,
        a.practice_line_1,
        a.practice_city,
        a.practice_state,
        a.practice_zip,
        a.b1_status,
        a.b1_nppes_pml_mismatch,
        a.b1_nppes_zip9,
        a.b1_pml_zip9,
        b.b3_nppes_taxonomy_count,
        b.b3_fl_allowed_count,
        b.b3_at_least_one_viable_in_fl,
        b.b3_no_viable_in_fl,
        b.b3_status
      from `{project}.{dataset}.npi_addresses_fl` a
      left join `{project}.{dataset}.b3_taxonomy_alignment_fl` b on b.npi = a.npi
    )
    """

    buckets = [
        ("no_issues", "not b1_nppes_pml_mismatch and coalesce(b3_at_least_one_viable_in_fl, false)", 25),
        ("b1_only", "b1_nppes_pml_mismatch and coalesce(b3_at_least_one_viable_in_fl, false)", 25),
        ("b3_only", "not b1_nppes_pml_mismatch and coalesce(b3_no_viable_in_fl, false)", 25),
        ("both", "b1_nppes_pml_mismatch and coalesce(b3_no_viable_in_fl, false)", 10),
    ]

    for bucket_name, where_clause, limit in buckets:
        q = base + f" select * from j where {where_clause} order by npi limit {limit}"
        rows = list(client.query(q).result())
        if not rows:
            print(f"  {bucket_name}: 0 rows (none found)")
            continue
        out = reports_dir / f"b1_b3_samples_{bucket_name}.csv"
        cols = list(rows[0].keys())
        with open(out, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
            w.writeheader()
            for r in rows:
                w.writerow({k: ("" if v is None else str(v)) for k, v in r.items()})
        print(f"  {bucket_name}: {len(rows)} rows -> {out.name}")

    print()
    print("Done. Open reports/b1_b3_samples_*.csv to review.")


if __name__ == "__main__":
    main()
