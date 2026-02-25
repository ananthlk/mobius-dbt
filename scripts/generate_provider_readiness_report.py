#!/usr/bin/env python3
"""
Export FL Medicaid NPI provider readiness report to CSV and Markdown.
Run after: dbt run --select +provider_readiness_report +provider_propensity_score_fl

Usage:
  uv run python scripts/generate_provider_readiness_report.py
  REPORT_DATE=2026-02-01 uv run python scripts/generate_provider_readiness_report.py

Output:
  reports/provider_readiness_{date}.csv
  reports/provider_readiness_{date}.md
  reports/provider_propensity_{date}.csv
"""

import csv
import os
import sys
from datetime import datetime
from pathlib import Path

def main() -> int:
    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    dataset = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")
    report_date = os.environ.get("REPORT_DATE", datetime.now().strftime("%Y-%m-%d"))
    repo_root = Path(__file__).resolve().parents[1]
    reports_dir = repo_root / "reports"
    reports_dir.mkdir(exist_ok=True)

    try:
        from google.cloud import bigquery
    except ImportError:
        print("Install: pip install google-cloud-bigquery", file=sys.stderr)
        return 1

    client = bigquery.Client(project=project)

    # 1. Report rows (core columns for CSV)
    report_table = f"`{project}.{dataset}.provider_readiness_report`"
    report_cols = [
        "report_date", "billing_npi", "servicing_npi", "status_flag", "readiness_score",
        "billing_org_name", "servicing_provider_name", "total_paid", "claim_count", "beneficiary_count",
        "status_message_today", "reason_today", "reason_3mo",
        "issue_b1", "issue_b2", "issue_b3", "issue_c1", "issue_c2", "issue_c3", "issue_c4", "issue_d", "issue_f",
    ]
    report_csv = reports_dir / f"provider_readiness_{report_date.replace('-','')}.csv"

    print(f"Querying provider_readiness_report...")
    try:
        query = f"SELECT {', '.join(report_cols)} FROM {report_table}"
        rows = list(client.query(query).result())
        if rows:
            with open(report_csv, "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=[k for k in rows[0].keys()])
                w.writeheader()
                for r in rows:
                    w.writerow({k: ("" if v is None else str(v)) for k, v in r.items()})
            print(f"  Wrote {len(rows)} rows to {report_csv}")
        else:
            print(f"  No rows (table may be empty).")
    except Exception as e:
        print(f"  Error: {e}")

    # 2. Propensity score (top by score)
    pps_table = f"`{project}.{dataset}.provider_propensity_score_fl`"
    pps_csv = reports_dir / f"provider_propensity_{report_date.replace('-','')}.csv"

    print(f"Querying provider_propensity_score_fl...")
    try:
        query = f"SELECT billing_npi, npi, status_flag, propensity_score, enrollment_score, address_score, taxonomy_score, utilization_score, total_paid, claim_count FROM {pps_table} ORDER BY propensity_score DESC"
        rows = list(client.query(query).result())
        if rows:
            with open(pps_csv, "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=[k for k in rows[0].keys()])
                w.writeheader()
                for r in rows:
                    w.writerow({k: ("" if v is None else str(v)) for k, v in r.items()})
            print(f"  Wrote {len(rows)} rows to {pps_csv}")
        else:
            print(f"  No rows.")
    except Exception as e:
        print(f"  Error: {e}")

    # 3. Markdown summary
    md_path = reports_dir / f"provider_readiness_{report_date.replace('-','')}.md"
    print(f"Writing Markdown summary to {md_path}...")
    with open(md_path, "w") as f:
        f.write(f"# FL Medicaid NPI Provider Readiness Report\n\n")
        f.write(f"**Report Date:** {report_date}  \n**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n---\n\n")
        try:
            # Aggregate from report
            agg = list(client.query(f"""
                SELECT
                  COUNT(*) as total_rows,
                  COUNT(DISTINCT billing_npi) as billing_orgs,
                  COUNT(DISTINCT servicing_npi) as servicing_providers,
                  COALESCE(SUM(total_paid), 0) as total_paid,
                  COALESCE(SUM(claim_count), 0) as claim_count,
                  COUNTIF(status_flag = 'Green') as green,
                  COUNTIF(status_flag = 'Yellow') as yellow,
                  COUNTIF(status_flag = 'Red') as red
                FROM {report_table}
            """).result())[0]
            f.write("## Executive Summary\n\n")
            f.write("| Metric | Value |\n|--------|------|\n")
            f.write(f"| Total Rows | {agg.get('total_rows', 0)} |\n")
            f.write(f"| Billing Orgs | {agg.get('billing_orgs', 0)} |\n")
            f.write(f"| Servicing Providers | {agg.get('servicing_providers', 0)} |\n")
            f.write(f"| Total Billed | ${agg.get('total_paid', 0):,.0f} |\n")
            f.write(f"| Total Claims | {agg.get('claim_count', 0):,} |\n")
            f.write(f"| Green | {agg.get('green', 0)} |\n")
            f.write(f"| Yellow | {agg.get('yellow', 0)} |\n")
            f.write(f"| Red | {agg.get('red', 0)} |\n\n")
        except Exception as e:
            f.write(f"*Could not compute summary: {e}*\n\n")
        f.write("## Outputs\n\n")
        f.write(f"- `{report_csv.name}` — Full report rows\n")
        f.write(f"- `{pps_csv.name}` — Propensity scores (0–100)\n")
    print(f"  Done.")

    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
