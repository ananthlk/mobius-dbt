#!/usr/bin/env python3
"""
Debug invalid combos for Aspire interactive report.

Checks:
1. Scope: Are readiness rows restricted to L3 locations? (We may be including rows for dropped L1 sites)
2. Roster alignment: Does each invalid combo's (servicing_npi, site) exist in our npis_per_location?
3. Readiness status breakdown sanity
4. Duplicate combos: same (servicing_npi, taxonomy, zip9) appearing multiple times

Usage:
  uv run python scripts/debug_invalid_combos.py
  uv run python scripts/debug_invalid_combos.py --report-dir reports/Aspire_Health_Partners/interactive_sim/20260307_1131
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import sys
from collections import defaultdict
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


def _load_csv(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with open(path, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def _normalize_site(row: dict) -> str:
    """Build comparable site key from address fields."""
    addr = str(row.get("site_address_line_1") or "").strip().upper()
    city = str(row.get("site_city") or "").strip().upper()
    state = str(row.get("site_state") or "").strip().upper()
    zip_ = str(row.get("site_zip") or "").strip()
    if len(zip_) == 9 and zip_.isdigit():
        zip5 = zip_[:5]
    else:
        zip5 = zip_[:5] if len(zip_) >= 5 else zip_
    return f"{addr}|{city}|{state}|{zip5}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Debug invalid combos")
    parser.add_argument(
        "--report-dir",
        default=None,
        help="Report directory (default: latest interactive_sim timestamp)",
    )
    args = parser.parse_args()

    base = _repo_root / "mobius-dbt" / "reports" / "Aspire_Health_Partners" / "interactive_sim"
    if args.report_dir:
        report_dir = Path(args.report_dir)
        if not report_dir.is_absolute():
            report_dir = base.parent.parent.parent / args.report_dir
    else:
        # Find latest timestamp dir
        if not base.exists():
            print(f"Report dir not found: {base}", file=sys.stderr)
            return 1
        subdirs = sorted([d for d in base.iterdir() if d.is_dir()], reverse=True)
        if not subdirs:
            print("No timestamp subdirs in interactive_sim", file=sys.stderr)
            return 1
        report_dir = subdirs[0]

    # Find CSVs (prefix varies by timestamp)
    combos_files = [f for f in report_dir.glob("*_combos.csv") if "invalid" not in f.name]
    invalid_files = list(report_dir.glob("*_invalid_combos.csv"))
    locations_files = list(report_dir.glob("*_locations.csv"))
    npis_files = list(report_dir.glob("*_npis_per_location.csv"))
    locations_match = list(report_dir.glob("*_locations_match_report.csv"))

    combos_path = combos_files[0] if combos_files else None
    invalid_path = invalid_files[0] if invalid_files else None
    locations_path = locations_files[0] if locations_files else None
    npis_path = npis_files[0] if npis_files else None

    if not invalid_path or not combos_path:
        print(f"Missing invalid_combos or combos CSV in {report_dir}", file=sys.stderr)
        return 1

    combos = _load_csv(combos_path)
    invalid = _load_csv(invalid_path)
    locations = _load_csv(locations_path) if locations_path else []
    npis_per_loc = _load_csv(npis_path) if npis_path else []

    print("=" * 70)
    print("INVALID COMBOS DEBUG")
    print("=" * 70)
    print(f"Report dir: {report_dir}")
    print(f"Total combos: {len(combos)}")
    print(f"Invalid combos: {len(invalid)}")
    print(f"Ready combos: {len(combos) - len(invalid)}")
    print()

    # 1. L3 site keys
    l3_sites = {_normalize_site(loc) for loc in locations}
    print("--- 1. SCOPE: Readiness rows vs L3 locations ---")
    print(f"L3 locations count: {len(locations)}")
    print(f"L3 unique site keys: {len(l3_sites)}")

    invalid_sites = set()
    invalid_sites_detail: dict[str, int] = defaultdict(int)
    for r in invalid:
        sk = _normalize_site(r)
        invalid_sites.add(sk)
        invalid_sites_detail[sk] += 1

    in_l3 = invalid_sites & l3_sites
    not_in_l3 = invalid_sites - l3_sites
    print(f"Invalid combo sites (unique): {len(invalid_sites)}")
    print(f"  In L3: {len(in_l3)} sites, {sum(invalid_sites_detail[s] for s in in_l3)} rows")
    print(f"  NOT in L3: {len(not_in_l3)} sites, {sum(invalid_sites_detail[s] for s in not_in_l3)} rows")
    if not_in_l3:
        print("  Non-L3 sites (first 5):")
        for s in list(not_in_l3)[:5]:
            print(f"    {s} -> {invalid_sites_detail[s]} invalid rows")
    print()

    # 2. Roster alignment: (servicing_npi, location) in npis_per_location?
    # Build lookup: location_id -> set(servicing_npi)
    loc_id_to_addr: dict[str, dict] = {loc["location_id"]: loc for loc in locations}
    npi_at_loc: set[tuple[str, str]] = set()
    for row in npis_per_loc:
        lid = row.get("location_id") or ""
        npi = row.get("servicing_npi") or ""
        if lid and npi:
            npi_at_loc.add((npi, lid))

    # For invalid rows we have (site_address, site_city, site_state, site_zip) - need to map to location_id
    def _site_to_loc_ids(site_row: dict) -> list[str]:
        out = []
        addr = (site_row.get("site_address_line_1") or "").strip()
        city = (site_row.get("site_city") or "").strip()
        state = (site_row.get("site_state") or "").strip()
        zip_ = (site_row.get("site_zip") or "").strip()
        for lid, loc in loc_id_to_addr.items():
            la = str(loc.get("site_address_line_1") or "").strip().upper()
            lc = str(loc.get("site_city") or "").strip().upper()
            ls = str(loc.get("site_state") or "").strip().upper()
            lz = str(loc.get("site_zip") or "").strip()
            if len(zip_) >= 5 and len(lz) >= 5:
                if la == addr.upper() and lc == city.upper() and ls == state.upper() and zip_[:5] == lz[:5]:
                    out.append(lid)
        return out

    not_in_roster = 0
    in_roster = 0
    for r in invalid:
        npi = r.get("servicing_npi") or ""
        lids = _site_to_loc_ids(r)
        found = any((npi, lid) in npi_at_loc for lid in lids)
        if found:
            in_roster += 1
        else:
            not_in_roster += 1

    print("--- 2. ROSTER ALIGNMENT ---")
    print(f"Invalid combos where (servicing_npi, site) is in npis_per_location: {in_roster}")
    print(f"Invalid combos where (servicing_npi, site) NOT in npis_per_location: {not_in_roster}")
    if not_in_roster > 0:
        print("  (Readiness uses bh_roster sites; npis_per_location uses L3. Site format may differ.)")
    print()

    # 3. Readiness status breakdown
    print("--- 3. READINESS STATUS BREAKDOWN ---")
    by_status: dict[str, int] = defaultdict(int)
    for r in invalid:
        by_status[r.get("readiness_status") or "unknown"] += 1
    for st, cnt in sorted(by_status.items(), key=lambda x: -x[1]):
        print(f"  {st}: {cnt}")
    print(f"  Sum: {sum(by_status.values())}")
    print()

    # 4. Duplicate combos
    print("--- 4. DUPLICATE CHECK ---")
    combo_key = lambda r: (r.get("servicing_npi"), r.get("provider_taxonomy_code"), r.get("servicing_zip9"))
    seen: dict[tuple, int] = defaultdict(int)
    for r in invalid:
        seen[combo_key(r)] += 1
    dups = {k: v for k, v in seen.items() if v > 1}
    print(f"Unique (servicing_npi, taxonomy, zip9) in invalid: {len(seen)}")
    print(f"Duplicates (count > 1): {len(dups)}")
    if dups:
        for k, v in list(dups.items())[:3]:
            print(f"  {k} -> {v} times")
    print()

    # 5. Sample invalid rows
    print("--- 5. SAMPLE INVALID (first 3 per status) ---")
    by_status_list: dict[str, list] = defaultdict(list)
    for r in invalid:
        st = r.get("readiness_status") or "unknown"
        if len(by_status_list[st]) < 3:
            by_status_list[st].append(r)
    for st in ["Not enrolled", "Invalid address", "Taxonomy not permitted", "Combo mismatch"]:
        for r in by_status_list.get(st, [])[:3]:
            print(f"  [{st}] {r.get('servicing_npi')} {r.get('servicing_provider_name')} | {r.get('provider_taxonomy_code')} | {r.get('site_address_line_1')}, {r.get('site_city')}")
    print()
    print("=" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())
