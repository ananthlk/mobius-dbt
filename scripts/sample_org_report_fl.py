#!/usr/bin/env python3
"""
Produce a sample FL Medicaid NPI report for one organization from the B6 integrated report.

Uses b6_integrated_report_fl (single read head). Looks up by org display name (e.g. "Aspire Behavioral Health")
or by org_id (billing NPI).

Env:
  BQ_PROJECT (default: mobius-os-dev)
  BQ_MARTS_MEDICAID_DATASET (default: mobius_medicaid_npi_dev)

Usage:
  python scripts/sample_org_report_fl.py "Aspire Behavioral Health"
  python scripts/sample_org_report_fl.py --org-id 1234567890
  python scripts/sample_org_report_fl.py "Aspire" --output report.md
"""

import argparse
import json
import os
import sys
from pathlib import Path

_project_root = Path(__file__).resolve().parent.parent
try:
    from dotenv import load_dotenv
    load_dotenv(_project_root / ".env", override=True)
except ImportError:
    pass

try:
    from google.cloud import bigquery
except ImportError:
    print("Install google-cloud-bigquery: pip install google-cloud-bigquery", file=sys.stderr)
    sys.exit(1)


def _run_query(
    bq_client: bigquery.Client,
    project: str,
    dataset: str,
    org_name_substring: str | None = None,
    org_id: str | None = None,
) -> list:
    table = f"`{project}.{dataset}.b6_integrated_report_fl`"
    # Restrict to latest partition for live interaction (table is partitioned by report_date)
    latest = f"(SELECT MAX(report_date) FROM {table})"
    if org_id:
        query = f"""
        SELECT * FROM {table}
        WHERE report_date = {latest}
          AND org_id = @org_id
        ORDER BY site_id, npi
        """
        job_config = bigquery.QueryJobConfig(
            query_parameters=[bigquery.ScalarQueryParameter("org_id", "STRING", org_id)]
        )
    elif org_name_substring:
        query = f"""
        SELECT * FROM {table}
        WHERE report_date = {latest}
          AND LOWER(COALESCE(org_display_name, '')) LIKE LOWER(@pattern)
        ORDER BY org_id, site_id, npi
        """
        pattern = f"%{org_name_substring.strip()}%"
        job_config = bigquery.QueryJobConfig(
            query_parameters=[bigquery.ScalarQueryParameter("pattern", "STRING", pattern)]
        )
    else:
        raise ValueError("Provide --org-name or --org-id")
    return [dict(row) for row in bq_client.query(query, job_config=job_config).result()]


def _row_to_md(row: dict) -> str:
    """Format one B6 row as markdown sections."""
    lines = []
    # Org / site header
    lines.append("## " + (row.get("org_display_name") or row.get("org_id") or "Unknown"))
    lines.append("")
    lines.append(f"- **org_id:** {row.get('org_id')} | **site_id:** {row.get('site_id')} | **billing_npi:** {row.get('billing_npi')}")
    lines.append(f"- **NPI:** {row.get('npi')} — {row.get('npi_provider_name') or '—'}")
    lines.append(f"- **TIN:** {row.get('tin')} | **source_type:** {row.get('source_type')}")
    lines.append("")
    # Site address
    if row.get("site_address_line_1") or row.get("site_city"):
        addr = ", ".join(
            x for x in [
                row.get("site_address_line_1"),
                row.get("site_city"),
                row.get("site_state"),
                row.get("site_zip5") or row.get("site_zip9"),
            ] if x
        )
        lines.append(f"**Site:** {addr}")
        lines.append("")
    # Validation status
    lines.append("### Validation status")
    lines.append("")
    lines.append("| Check | Status |")
    lines.append("|-------|--------|")
    b1 = row.get("b1_status") or "—"
    b2 = "info" if row.get("b2_mailing_vs_practice_mismatch") else "—"
    b3 = row.get("b3_status") or "—"
    b4_ok = "pass" if row.get("b4_has_permissible_id") else ("fail" if row.get("b4_no_medicaid_id_in_pml") else "—")
    b5 = "pass" if row.get("b5_pass") else (row.get("b5_fail_reason") or "—")
    lines.append(f"| B1 (address) | {b1} |")
    lines.append(f"| B2 (mailing vs practice) | {b2} |")
    lines.append(f"| B3 (taxonomy) | {b3} |")
    lines.append(f"| B4 (Medicaid ID) | {b4_ok} |")
    lines.append(f"| B5 (combined) | {b5} |")
    lines.append("")
    # B1 detail if not pass
    if row.get("b1_nppes_pml_mismatch") or row.get("b1_zip9_match") is False:
        lines.append("**B1 detail:**")
        lines.append(f"- NPPES ZIP+9: {row.get('b1_nppes_zip9') or '—'}")
        lines.append(f"- PML ZIP+9: {row.get('b1_pml_zip9') or '—'}")
        lines.append(f"- b1_zip9_match: {row.get('b1_zip9_match')}")
        lines.append("")
    # Practice / mailing
    lines.append("**Practice address:** " + ", ".join(
        x for x in [
            row.get("practice_line_1"),
            row.get("practice_city"),
            row.get("practice_state"),
            row.get("practice_zip"),
        ] if x
    ) or "—")
    lines.append("")
    lines.append("**Mailing address:** " + ", ".join(
        x for x in [
            row.get("mailing_line_1"),
            row.get("mailing_city"),
            row.get("mailing_state"),
            row.get("mailing_zip"),
        ] if x
    ) or "—")
    lines.append("")
    # B4 Medicaid IDs
    b4_ids = row.get("b4_medicaid_ids")
    if b4_ids:
        ids_str = ", ".join(
            f"{e.get('medicaid_provider_id')} (permissible={e.get('b4_permissible')})"
            for e in (b4_ids if isinstance(b4_ids, list) else [])
        )
        if ids_str:
            lines.append(f"**B4 Medicaid IDs:** {ids_str}")
            lines.append("")
    lines.append("---")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Produce a sample FL Medicaid NPI report for one organization from B6."
    )
    parser.add_argument(
        "org_name",
        nargs="?",
        default=None,
        help='Org display name substring (e.g. "Aspire Behavioral Health")',
    )
    parser.add_argument(
        "--org-id",
        default=None,
        help="Exact org_id (billing NPI or address-based org id) to filter.",
    )
    parser.add_argument(
        "--output", "-o",
        default=None,
        help="Write report to this file instead of stdout.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output raw JSON rows instead of markdown.",
    )
    args = parser.parse_args()

    org_name = args.org_name or (None if args.org_id else "Aspire Behavioral Health")
    if not org_name and not args.org_id:
        parser.error("Provide org name or --org-id")

    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    dataset = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")

    client = bigquery.Client(project=project)
    try:
        rows = _run_query(
            client,
            project,
            dataset,
            org_name_substring=org_name if not args.org_id else None,
            org_id=args.org_id,
        )
    except Exception as e:
        print(f"Query failed: {e}", file=sys.stderr)
        sys.exit(1)

    if not rows:
        msg = f"No rows found for org name like '{org_name}'" if not args.org_id else f"No rows found for org_id '{args.org_id}'"
        print(msg, file=sys.stderr)
        print("Ensure dbt has been run and landing data is loaded.", file=sys.stderr)
        sys.exit(1)

    out = sys.stdout if not args.output else open(args.output, "w")
    try:
        if args.json:
            json.dump(rows, out, indent=2, default=str)
        else:
            out.write("# FL Medicaid NPI — Sample org report\n\n")
            out.write(f"**Organization:** {org_name or args.org_id}  \n")
            out.write(f"**Rows:** {len(rows)}  \n\n")
            out.write("---\n\n")
            for row in rows:
                out.write(_row_to_md(row))
    finally:
        if args.output and out != sys.stdout:
            out.close()

    if args.output:
        print(f"Wrote {len(rows)} row(s) to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
