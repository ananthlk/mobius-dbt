#!/usr/bin/env python3
"""
Run B1 and B3 models then print a short review: B1 (address) and B3 (taxonomy + address org).
B1 has its own table (npi_addresses_fl); B3 taxonomy has its own (b3_taxonomy_alignment_fl).
B3 address org lives in address_validation_fl (issue_b3). We can bring them together later.

Usage: from mobius-dbt, run:
  uv run dbt run --select npi_addresses_fl b3_taxonomy_alignment_fl address_validation_fl
  uv run python scripts/run_b1_b3_review.py
Or run this script only to query already-built views.
"""

from __future__ import annotations

import os
import subprocess
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
    client = bigquery.Client(project=project)

    # Optional: run dbt for B1 + B3
    run_dbt = os.environ.get("RUN_DBT", "").lower() in ("1", "true", "yes")
    if run_dbt:
        dbt_dir = Path(__file__).resolve().parent.parent
        subprocess.run(
            ["uv", "run", "dbt", "run", "--select", "npi_addresses_fl", "b3_taxonomy_alignment_fl", "address_validation_fl"],
            cwd=dbt_dir,
            check=True,
        )

    print("=" * 60)
    print("B1 (address alignment) — table: npi_addresses_fl")
    print("=" * 60)
    q_b1 = f"""
    select
      count(*) as total,
      countif(b1_nppes_pml_mismatch = false) as b1_pass,
      countif(b1_nppes_pml_mismatch = true)  as b1_severe
    from `{project}.{dataset}.npi_addresses_fl`
    """
    row = next(client.query(q_b1).result())
    print(f"  Total rows: {row.total}")
    print(f"  B1 pass (matched):   {row.b1_pass}")
    print(f"  B1 severe (missed): {row.b1_severe}")
    print()
    q_b1_status = f"""
    select b1_status, count(*) as n
    from `{project}.{dataset}.npi_addresses_fl`
    group by 1 order by 2 desc
    limit 10
    """
    print("  B1 status breakdown (top):")
    for r in client.query(q_b1_status).result():
        print(f"    {r.b1_status}: {r.n}")
    print()

    print("=" * 60)
    print("B3 taxonomy alignment — table: b3_taxonomy_alignment_fl")
    print("=" * 60)
    q_b3 = f"""
    select
      count(*) as total,
      countif(b3_at_least_one_viable_in_fl) as at_least_one_viable,
      countif(b3_no_viable_in_fl) as no_viable_in_fl
    from `{project}.{dataset}.b3_taxonomy_alignment_fl`
    """
    row = next(client.query(q_b3).result())
    print(f"  Total rows: {row.total}")
    print(f"  At least one viable in FL: {row.at_least_one_viable}")
    print(f"  No viable in FL:           {row.no_viable_in_fl}")
    print()
    q_b3_status = f"""
    select b3_status, count(*) as n
    from `{project}.{dataset}.b3_taxonomy_alignment_fl`
    group by 1 order by 2 desc
    """
    print("  B3 status breakdown:")
    for r in client.query(q_b3_status).result():
        print(f"    {r.b3_status}: {r.n}")
    print()

    print("=" * 60)
    print("B3 address (org outlier) — in address_validation_fl as issue_b3")
    print("=" * 60)
    q_av = f"""
    select
      count(*) as total_pairs,
      countif(issue_b1) as issue_b1,
      countif(issue_b2) as issue_b2,
      countif(issue_b3) as issue_b3
    from `{project}.{dataset}.address_validation_fl`
    """
    row = next(client.query(q_av).result())
    print(f"  Total (billing_npi, servicing_npi) pairs: {row.total_pairs}")
    print(f"  issue_b1 (address ZIP+9): {row.issue_b1}")
    print(f"  issue_b2 (mailing vs practice): {row.issue_b2}")
    print(f"  issue_b3 (address org outlier): {row.issue_b3}")
    print()
    print("B1 table: npi_addresses_fl  |  B3 taxonomy table: b3_taxonomy_alignment_fl  |  B3 address: address_validation_fl.issue_b3")
    print("Bring them together later (e.g. join on npi) for NPI + address + taxonomy + Medicaid ID.")


if __name__ == "__main__":
    main()
