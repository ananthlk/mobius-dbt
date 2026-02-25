#!/usr/bin/env python3
"""
Generate B6 integrated report for one org, NPI, or site.
Lookup by org_id, npi, site_id, or by org name (e.g. "Aspire Behavioral Health").
Output: reports/b6_report_<identifier>.md

Usage:
  python scripts/generate_b6_report.py --name "Aspire Behavioral Health"
  python scripts/generate_b6_report.py --org_id 1234567890
  python scripts/generate_b6_report.py --npi 1234567890
  python scripts/generate_b6_report.py --site_id 12345
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path


def main() -> None:
    try:
        from google.cloud import bigquery
    except ImportError:
        print("Install google-cloud-bigquery", file=__import__("sys").stderr)
        raise SystemExit(1)

    parser = argparse.ArgumentParser(description="Generate B6 integrated report by org_id, npi, site_id, or name")
    parser.add_argument("--org_id", type=str, help="Lookup by org_id (facility NPI or billing NPI)")
    parser.add_argument("--npi", type=str, help="Lookup by NPI")
    parser.add_argument("--site_id", type=str, help="Lookup by site_id (sub_org_id)")
    parser.add_argument("--name", type=str, help='Lookup by org name (e.g. "Aspire Behavioral Health")')
    parser.add_argument("--output", type=str, help="Output path (default reports/b6_report_<id>.md)")
    args = parser.parse_args()

    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    dataset = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")
    client = bigquery.Client(project=project)
    reports_dir = Path(__file__).resolve().parent.parent / "reports"
    reports_dir.mkdir(exist_ok=True)

    lookup_id: str | None = None
    lookup_type = ""

    if args.org_id:
        lookup_id = args.org_id.strip()
        lookup_type = "org_id"
    elif args.npi:
        lookup_id = args.npi.strip()
        lookup_type = "npi"
    elif args.site_id:
        lookup_id = args.site_id.strip()
        lookup_type = "site_id"
    elif args.name:
        name = args.name.strip()
        words = [w.strip().lower() for w in name.split() if w.strip()]
        if not words:
            print("--name must be non-empty", file=__import__("sys").stderr)
            raise SystemExit(1)
        like_clauses = " AND ".join(
            f"LOWER(org_name) LIKE '%{w}%'" for w in words
        )
        q_org = f"""
        SELECT billing_npi AS id FROM `{project}.{dataset}.organizations`
        WHERE {like_clauses}
        LIMIT 1
        """
        try:
            rows = list(client.query(q_org).result())
            if rows:
                lookup_id = str(rows[0].id)
                lookup_type = "org_id"
                print(f"Resolved name '{name}' -> org_id = {lookup_id}")
            else:
                like_npi = " AND ".join(
                    f"LOWER(COALESCE(provider_organization_name_legal_business_name,'')) LIKE '%{w}%'"
                    for w in words
                )
                q_npi = f"""
                SELECT CAST(npi AS STRING) AS id FROM `{project}.{dataset}.nppes_fl`
                WHERE entity_type_code = '2' AND ({like_npi})
                LIMIT 1
                """
                rows = list(client.query(q_npi).result())
                if rows:
                    lookup_id = str(rows[0].id)
                    lookup_type = "org_id"
                    print(f"Resolved name '{name}' -> org_id (facility NPI) = {lookup_id}")
                else:
                    print(f"No org or facility NPI found for name: {name}", file=__import__("sys").stderr)
                    raise SystemExit(1)
        except Exception as e:
            print(f"Lookup failed: {e}", file=__import__("sys").stderr)
            raise SystemExit(1)
    else:
        parser.print_help()
        print("\nProvide one of: --org_id, --npi, --site_id, --name", file=__import__("sys").stderr)
        raise SystemExit(1)

    table = f"`{project}.{dataset}.b6_integrated_report_fl`"
    if lookup_type == "org_id":
        where = f"(org_id = @id OR billing_npi = @id)"
    elif lookup_type == "npi":
        where = "npi = @id"
    else:
        where = "site_id = @id"

    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("id", "STRING", lookup_id),
        ]
    )
    q = f"SELECT * FROM {table} WHERE {where} ORDER BY npi, site_id"
    try:
        rows = list(client.query(q, job_config=job_config).result())
    except Exception as e:
        print(f"B6 query failed (is b6_integrated_report_fl built?): {e}", file=__import__("sys").stderr)
        raise SystemExit(1)

    if not rows:
        print(f"No rows in B6 for {lookup_type}={lookup_id}")
        out_path = reports_dir / f"b6_report_{lookup_type}_{lookup_id}.md"
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(f"# B6 Integrated Report — {lookup_type} = {lookup_id}\n\n")
            f.write("No rows found.\n")
        print(f"Wrote {out_path}")
        return

    safe_id = lookup_id.replace("/", "_").replace("\\", "_")
    out_path = Path(args.output) if args.output else reports_dir / f"b6_report_{lookup_type}_{safe_id}.md"
    lines: list[str] = []
    lines.append(f"# B6 Integrated Report — {lookup_type} = {lookup_id}")
    lines.append("")
    lines.append(f"**Rows:** {len(rows)} (one per npi × org × site)")
    lines.append("")
    r0 = rows[0]
    if getattr(r0, "org_display_name", None):
        lines.append(f"**Org display name:** {r0.org_display_name}")
        lines.append("")
    lines.append("---")
    lines.append("")

    for i, row in enumerate(rows, 1):
        lines.append(f"## Row {i} — NPI {getattr(row, 'npi', '')}")
        lines.append("")
        lines.append("### B0 Roster")
        lines.append(f"- **org_id:** {getattr(row, 'org_id', '')}")
        lines.append(f"- **site_id:** {getattr(row, 'site_id', '')}")
        lines.append(f"- **npi:** {getattr(row, 'npi', '')}")
        lines.append(f"- **billing_npi:** {getattr(row, 'billing_npi', '')}")
        lines.append(f"- **source_type:** {getattr(row, 'source_type', '')}")
        lines.append(f"- **npi_provider_name:** {getattr(row, 'npi_provider_name', '')}")
        assoc = getattr(row, 'associated_member_npis', None)
        if assoc is not None and list(assoc) if hasattr(assoc, '__iter__') else assoc:
            lines.append(f"- **associated_member_npis:** {list(assoc) if hasattr(assoc, '__iter__') and not isinstance(assoc, str) else assoc}")
        lines.append("")
        lines.append("### Site address")
        lines.append(f"- **site_address_line_1:** {getattr(row, 'site_address_line_1', '')}")
        lines.append(f"- **site_city:** {getattr(row, 'site_city', '')} **site_state:** {getattr(row, 'site_state', '')} **site_zip5:** {getattr(row, 'site_zip5', '')}")
        lines.append("")
        lines.append("### B1 NPPES vs PML alignment")
        lines.append(f"- **b1_status:** {getattr(row, 'b1_status', '')}")
        lines.append(f"- **b1_nppes_pml_mismatch:** {getattr(row, 'b1_nppes_pml_mismatch', '')}")
        lines.append(f"- **b1_zip9_match:** {getattr(row, 'b1_zip9_match', '')}")
        lines.append(f"- **b1_nppes_zip9:** {getattr(row, 'b1_nppes_zip9', '')} **b1_pml_zip9:** {getattr(row, 'b1_pml_zip9', '')}")
        lines.append("")
        lines.append("### B2 Address info")
        lines.append(f"- **b2_mailing_vs_practice_mismatch:** {getattr(row, 'b2_mailing_vs_practice_mismatch', '')}")
        lines.append(f"- **practice:** {getattr(row, 'practice_line_1', '')}, {getattr(row, 'practice_city', '')} {getattr(row, 'practice_state', '')} {getattr(row, 'practice_zip', '')}")
        lines.append(f"- **mailing:** {getattr(row, 'mailing_line_1', '')}, {getattr(row, 'mailing_city', '')} {getattr(row, 'mailing_state', '')} {getattr(row, 'mailing_zip', '')}")
        lines.append("")
        lines.append("### B3 Taxonomy alignment")
        lines.append(f"- **b3_status:** {getattr(row, 'b3_status', '')}")
        lines.append(f"- **b3_at_least_one_viable_in_fl:** {getattr(row, 'b3_at_least_one_viable_in_fl', '')} **b3_no_viable_in_fl:** {getattr(row, 'b3_no_viable_in_fl', '')}")
        lines.append(f"- **b3_nppes_taxonomy_count:** {getattr(row, 'b3_nppes_taxonomy_count', '')} **b3_fl_allowed_count:** {getattr(row, 'b3_fl_allowed_count', '')}")
        lines.append("")
        lines.append("### B4 Medicaid ID")
        lines.append(f"- **b4_medicaid_id_count:** {getattr(row, 'b4_medicaid_id_count', '')}")
        lines.append(f"- **b4_has_permissible_id:** {getattr(row, 'b4_has_permissible_id', '')} **b4_no_medicaid_id_in_pml:** {getattr(row, 'b4_no_medicaid_id_in_pml', '')}")
        b4_ids = getattr(row, 'b4_medicaid_ids', None)
        if b4_ids is not None and list(b4_ids) if hasattr(b4_ids, '__iter__') else b4_ids:
            lines.append(f"- **b4_medicaid_ids:** {list(b4_ids)}")
        lines.append("")
        lines.append("### B5 Final alignment (NPI + Medicaid ID + taxonomy + site)")
        lines.append(f"- **b5_pass:** {getattr(row, 'b5_pass', '')}")
        lines.append(f"- **b5_fail_reason:** {getattr(row, 'b5_fail_reason', '')}")
        lines.append("")
        lines.append("---")
        lines.append("")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"Wrote {out_path} ({len(rows)} rows)")


if __name__ == "__main__":
    main()
