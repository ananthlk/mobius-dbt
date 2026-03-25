#!/usr/bin/env python3
"""
Simulate interactive mode for Aspire Health Partners.

Flow:
  1. Extract org name, fetch L1 (system-imputed) locations
  2. [PAUSE] Display L1 → Use L2 from aspire_locations_override.json (user override)
  3. Normalize L1 + L2, merge to L3
  4. NPI list assembly (L1 + L2 address match)
  5. [PAUSE] Display NPIs → (simulation: no corrections)
  6. Build full report (all CSVs, metrics.json, MD)

Usage:
  uv run python scripts/simulate_interactive_aspire.py
  uv run python scripts/simulate_interactive_aspire.py --output-dir reports
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from datetime import datetime
from pathlib import Path

_repo_root = Path(__file__).resolve().parents[2]
_skill_path = _repo_root / "mobius-skills" / "provider-roster-credentialing"
if _skill_path.is_dir():
    sys.path.insert(0, str(_skill_path))
if (_repo_root / "mobius-config").exists():
    sys.path.insert(0, str(_repo_root / "mobius-config"))

try:
    from env_helper import load_env
    load_env(Path(__file__).resolve().parents[1])
except Exception:
    pass

ORG_NAME = "Aspire Health Partners"
OVERRIDE_PATH = _repo_root / "mobius-dbt" / "data" / "aspire_locations_override.json"


def _write_csv(filepath: Path, rows: list[dict], fieldnames: list[str] | None = None) -> None:
    if not rows:
        return
    keys = fieldnames or list(rows[0].keys())
    with open(filepath, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: ("" if v is None else str(v)) for k, v in r.items()})


def _write_md(filepath: Path, report: dict) -> None:
    ex = report.get("executive_summary") or {}
    if ex.get("error"):
        with open(filepath, "w", encoding="utf-8") as f:
            f.write("# Provider Roster / Credentialing Report\n\n")
            f.write(f"**Error:** {ex['error']}\n")
        return
    with open(filepath, "w", encoding="utf-8") as f:
        f.write("# Provider Roster / Credentialing Report (Interactive Mode)\n\n")
        f.write(f"**Organization:** {ex.get('org_name', '')}  \n")
        f.write(f"**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n---\n\n")
        f.write("## Executive Summary\n\n")
        f.write("| Metric | Value |\n|--------|------|\n")
        f.write(f"| Locations | {ex.get('location_count', 0)} |\n")
        f.write(f"| Total NPIs (control) | {ex.get('total_npis', 0)} |\n")
        f.write(f"| NPIs with readiness | {ex.get('npis_with_readiness', 0)} |\n")
        f.write(f"| NPIs no readiness | {ex.get('npis_no_readiness', 0)} |\n")
        f.write(f"| NPIs org name misaligned | {ex.get('npis_org_misaligned', 0)} |\n")
        f.write(f"| NPIs (all checks pass) | {ex.get('npis_all_checks_pass', 0)} |\n")
        f.write(f"| NPIs (at least one fail) | {ex.get('npis_at_least_one_fail', 0)} |\n")
        f.write(f"| Invalid combos | {ex.get('invalid_combo_count', 0)} |\n")
        f.write(f"| Ghost billing (NPIs) | {ex.get('ghost_billing_npi_count', 0)} |\n")
        f.write(f"| Ghost billing (claims) | {ex.get('ghost_billing_claim_count', 0)} |\n")
        f.write(f"| Ghost billing ($) | ${ex.get('ghost_billing_total_paid', 0):,.0f} |\n")
        f.write("\n**Readiness status breakdown:**\n\n")
        for status, count in (ex.get("readiness_status_breakdown") or {}).items():
            f.write(f"- {status}: {count}\n")
        f.write(f"\n**Next steps:** {ex.get('next_steps', '')}\n\n---\n\n")
        f.write("## Outputs\n\n")
        f.write("See CSV files in the same directory: locations, npis_per_location, per_npi_validation, combos, invalid_combos, ghost_billing, missed_opportunities, locations_match_report, l1_not_in_l2.\n")


def main() -> int:
    try:
        from google.cloud import bigquery
    except ImportError:
        print("Install: pip install google-cloud-bigquery", file=sys.stderr)
        return 1

    try:
        from app.core import get_locations, build_full_report
        from app.address_normalizer import normalized_address_key, extract_zip5, normalize_street
    except ImportError as e:
        print(f"Cannot import: {e}. Ensure mobius-skills/provider-roster-credentialing exists.", file=sys.stderr)
        return 1

    parser = argparse.ArgumentParser(description="Simulate interactive mode for Aspire (full report output)")
    parser.add_argument("--output-dir", default=None, help="Output directory (default: reports/Aspire_Health_Partners/interactive_sim)")
    args = parser.parse_args()

    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    marts_dataset = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")
    landing_dataset = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")
    base = Path(args.output_dir) if args.output_dir else _repo_root / "mobius-dbt" / "reports" / "Aspire_Health_Partners" / "interactive_sim"
    ts = datetime.now().strftime("%Y%m%d_%H%M")
    output_dir = base / ts
    output_dir.mkdir(parents=True, exist_ok=True)
    prefix = f"interactive_sim_aspire_{ts}"

    print("=" * 70)
    print("INTERACTIVE MODE SIMULATION: Aspire Health Partners")
    print("=" * 70)

    client = bigquery.Client(project=project)

    # Step 1: Extract org, fetch L1
    print("\n--- Step 1: Fetch system-imputed locations (L1) ---")
    l1_locations = get_locations(client, ORG_NAME, project, marts_dataset, state_filter="FL")
    if not l1_locations:
        print("  (No L1 locations in bh_roster for this org)")
    else:
        for i, loc in enumerate(l1_locations, 1):
            addr = loc.get("site_address_line_1") or ""
            city = loc.get("site_city") or ""
            state = loc.get("site_state") or ""
            zip_ = loc.get("site_zip") or loc.get("site_zip9") or ""
            norm_key = normalized_address_key(addr, city, state, zip_)
            print(f"  {i}. {addr}, {city}, {state} {zip_}  [norm_key={norm_key[:50]}...]")
    print(f"  L1 count: {len(l1_locations)}")

    # [PAUSE] User override - load from file
    print("\n--- [PAUSE] User override (L2) - loading from aspire_locations_override.json ---")
    if not OVERRIDE_PATH.exists():
        print(f"  ERROR: Override file not found: {OVERRIDE_PATH}")
        return 1
    with open(OVERRIDE_PATH, encoding="utf-8") as f:
        override_data = json.load(f)
    locations_override = override_data.get("locations_override", override_data.get("locations", []))
    if not isinstance(locations_override, list):
        locations_override = []
    print(f"  L2 count: {len(locations_override)}")
    for i, loc in enumerate(locations_override[:5], 1):
        a = loc.get("site_address_line_1", "")
        c = loc.get("site_city", "")
        s = loc.get("site_state", "FL")
        z = loc.get("site_zip", "")
        print(f"  {i}. {a}, {c}, {s} {z}")
    if len(locations_override) > 5:
        print(f"  ... and {len(locations_override) - 5} more")

    # Step 2: Normalize + merge L3
    print("\n--- Step 2: Normalize L1 + L2, merge to L3 ---")
    report = build_full_report(
        client,
        org_name=ORG_NAME,
        project=project,
        marts_dataset=marts_dataset,
        landing_dataset=landing_dataset,
        location_ids=None,
        npi_overrides=None,
        locations_override=locations_override,
        state_filter="FL",
    )
    locations = report.get("locations") or []
    match_report = report.get("locations_match_report") or []
    l1_not_in_l2 = report.get("l1_not_in_l2") or []
    print(f"  L3 count: {len(locations)}")
    matched = sum(1 for r in match_report if r.get("match_source") == "l1_matched")
    new_ = sum(1 for r in match_report if r.get("match_source") == "l2_new")
    picked = sum(1 for r in match_report if r.get("npis_picked_up") == "yes")
    print(f"  Matched L1: {matched}, L2-new: {new_}, NPIs picked up: {picked} locations")
    if l1_not_in_l2:
        print(f"  L1 not in L2 (dropped): {len(l1_not_in_l2)}")

    # Show match details
    print("\n  Match report sample:")
    for r in match_report[:8]:
        src = r.get("match_source", "")
        addr = r.get("site_address_line_1", "")
        city = r.get("site_city", "")
        npi_cnt = r.get("npi_count", 0)
        tag = "L1_MATCHED" if src == "l1_matched" else "L2_NEW"
        print(f"    [{tag}] {addr}, {city} -> {npi_cnt} NPIs")

    # Step 3/4: NPI assembly + report (already done in build_full_report)
    ex = report.get("executive_summary") or {}
    print("\n--- Step 3–4: NPI assembly, readiness, report ---")
    print(f"  Location count: {ex.get('location_count', 0)}")
    print(f"  Total NPIs: {ex.get('total_npis', 0)}")
    print(f"  Invalid combos: {ex.get('invalid_combo_count', 0)}")

    # Write full report (same outputs as generate_provider_roster_credentialing_report.py)
    npi_rows = []
    for loc_id, nlist in (report.get("npis_per_location") or {}).items():
        for n in nlist:
            npi_rows.append({"location_id": loc_id, **n})

    _write_csv(output_dir / f"{prefix}_locations.csv", report.get("locations") or [])
    print(f"  Wrote {prefix}_locations.csv")
    _write_csv(output_dir / f"{prefix}_npis_per_location.csv", npi_rows)
    print(f"  Wrote {prefix}_npis_per_location.csv")
    _write_csv(output_dir / f"{prefix}_per_npi_validation.csv", report.get("per_npi_validation") or [])
    print(f"  Wrote {prefix}_per_npi_validation.csv")
    _write_csv(output_dir / f"{prefix}_combos.csv", report.get("combos") or [])
    print(f"  Wrote {prefix}_combos.csv")
    _write_csv(output_dir / f"{prefix}_invalid_combos.csv", report.get("invalid_combos") or [])
    print(f"  Wrote {prefix}_invalid_combos.csv")
    _write_csv(output_dir / f"{prefix}_ghost_billing.csv", report.get("ghost_billing") or [])
    print(f"  Wrote {prefix}_ghost_billing.csv")
    _write_csv(output_dir / f"{prefix}_missed_opportunities.csv", report.get("missed_opportunities") or [])
    print(f"  Wrote {prefix}_missed_opportunities.csv")
    _write_csv(output_dir / f"{prefix}_locations_match_report.csv", report.get("locations_match_report") or [])
    print(f"  Wrote {prefix}_locations_match_report.csv")
    _write_csv(output_dir / f"{prefix}_l1_not_in_l2.csv", report.get("l1_not_in_l2") or [])
    print(f"  Wrote {prefix}_l1_not_in_l2.csv")

    ex = report.get("executive_summary") or {}
    status_breakdown = ex.get("readiness_status_breakdown") or {}
    ready_count = status_breakdown.get("Ready") or 0
    invalid_count = ex.get("invalid_combo_count") or 0
    total_combo_count = ready_count + invalid_count
    metrics = {
        "org_name": ex.get("org_name"),
        "location_count": ex.get("location_count", 0),
        "total_npis": ex.get("total_npis", 0),
        "npis_with_readiness": ex.get("npis_with_readiness", 0),
        "npis_no_readiness": ex.get("npis_no_readiness", 0),
        "npis_org_misaligned": ex.get("npis_org_misaligned", 0),
        "npis_all_checks_pass": ex.get("npis_all_checks_pass", 0),
        "npis_at_least_one_fail": ex.get("npis_at_least_one_fail", 0),
        "invalid_combo_count": invalid_count,
        "ready_combo_count": ready_count,
        "total_combo_count": total_combo_count,
        "readiness_status_breakdown": status_breakdown,
        "revenue_at_risk_2024": ex.get("revenue_at_risk_2024"),
        "revenue_at_risk_2024_low": ex.get("revenue_at_risk_2024_low"),
        "revenue_at_risk_2024_high": ex.get("revenue_at_risk_2024_high"),
        "deprecated_taxonomy_revenue": ex.get("deprecated_taxonomy_revenue"),
        "revenue_by_location": ex.get("revenue_by_location") or [],
        "revenue_by_taxonomy": ex.get("revenue_by_taxonomy") or [],
        "revenue_assumptions": ex.get("revenue_assumptions") or {},
        "top_recommendations_by_code": ex.get("top_recommendations_by_code") or [],
        "recommendations_by_problem_type": ex.get("recommendations_by_problem_type") or [],
        "opportunity_confidence_matrix": ex.get("opportunity_confidence_matrix") or [],
        "confidence_definitions": ex.get("confidence_definitions") or {},
        "revenue_at_risk_2024_by_status": ex.get("revenue_at_risk_2024_by_status") or {},
        "revenue_at_risk_2024_by_confidence": ex.get("revenue_at_risk_2024_by_confidence") or {},
        "confidence_breakdown": ex.get("confidence_breakdown") or {"high": 0, "medium": 0, "low": 0},
        "readiness_score": ex.get("readiness_score"),
        "ghost_billing_npi_count": ex.get("ghost_billing_npi_count", 0),
        "ghost_billing_claim_count": ex.get("ghost_billing_claim_count", 0),
        "ghost_billing_total_paid": ex.get("ghost_billing_total_paid", 0),
        "missed_opportunities_count": len(report.get("missed_opportunities") or []),
    }
    with open(output_dir / f"{prefix}_metrics.json", "w", encoding="utf-8") as f:
        json.dump(metrics, f, indent=2)
    print(f"  Wrote {prefix}_metrics.json")

    _write_md(output_dir / "provider_roster_credentialing_report.md", report)
    print(f"  Wrote provider_roster_credentialing_report.md")

    print(f"\n  Full report outputs: {output_dir}")
    print("=" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())
