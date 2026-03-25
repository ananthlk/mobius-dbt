#!/usr/bin/env python3
"""Run report_writer on a fixture report (no BQ). Use to preview white-paper output."""
import os
import sys
from pathlib import Path

# Add skill package
_repo_root = Path(__file__).resolve().parents[2]
_skill_path = _repo_root / "mobius-skills" / "provider-roster-credentialing"
sys.path.insert(0, str(_skill_path))

# Load env (Vertex) from mobius-config
_config_dir = _repo_root / "mobius-config"
if _config_dir.exists():
    try:
        sys.path.insert(0, str(_config_dir))
        from env_helper import load_env
        load_env(_repo_root / "mobius-dbt")
    except Exception:
        pass

# Fixture matching build_full_report() shape (from David Lawrence run)
FIXTURE = {
    "executive_summary": {
        "org_name": "David Lawrence",
        "location_count": 4,
        "total_npis": 188,
        "npis_all_checks_pass": 124,
        "npis_at_least_one_fail": 64,
        "invalid_combo_count": 247,
        "ghost_billing_npi_count": 0,
        "ghost_billing_claim_count": 0,
        "ghost_billing_total_paid": 0,
        "readiness_status_breakdown": {
            "Ready": 612,
            "Not enrolled": 117,
            "Combo mismatch": 69,
            "Taxonomy not permitted": 8,
            "Invalid address": 53,
        },
        "next_steps": "247 invalid combo(s) need resolution.",
    },
    "locations": [
        {"org_name": "David Lawrence Center", "site_city": "Naples", "site_state": "FL", "site_zip": "34102"},
        {"org_name": "David Lawrence Center", "site_city": "Naples", "site_state": "FL", "site_zip": "34103"},
        {"org_name": "David Lawrence Center", "site_city": "Fort Myers", "site_state": "FL", "site_zip": "33901"},
        {"org_name": "David Lawrence Center", "site_city": "Bonita Springs", "site_state": "FL", "site_zip": "34134"},
    ],
    "invalid_combos": [
        {"servicing_npi": "1234567890", "servicing_provider_name": "Smith, Jane", "readiness_status": "Not enrolled", "readiness_summary": "NPI not found in PML or no active Medicaid ID."},
        {"servicing_npi": "0987654321", "servicing_provider_name": "Doe, John", "readiness_status": "Combo mismatch", "readiness_summary": "NPI+taxonomy+ZIP9 combo does not match PML enrollment."},
        {"servicing_npi": "1122334455", "servicing_provider_name": "Williams, A.", "readiness_status": "Invalid address", "readiness_summary": "ZIP+4 not 9 digits or missing."},
    ],
    "ghost_billing": [],
    "missed_opportunities": [{"type": "location_no_ready_npi", "location_id": "abc123"}],
}

def main():
    from app.report_writer import generate_white_paper_report
    provider = "gemini" if (os.getenv("BQ_PROJECT") or os.getenv("VERTEX_PROJECT_ID") or os.getenv("CHAT_VERTEX_PROJECT_ID") or os.getenv("GEMINI_API_KEY")) else "openai"
    if not (os.getenv("BQ_PROJECT") or os.getenv("VERTEX_PROJECT_ID") or os.getenv("CHAT_VERTEX_PROJECT_ID") or os.getenv("GEMINI_API_KEY") or os.getenv("OPENAI_API_KEY")):
        print("Set VERTEX_PROJECT_ID or GEMINI_API_KEY or OPENAI_API_KEY", file=sys.stderr)
        return 1
    print("Generating white-paper from fixture (David Lawrence)...")
    out = generate_white_paper_report(FIXTURE, provider=provider)
    out_path = Path(__file__).resolve().parents[1] / "reports" / "provider_roster_credentialing_white_paper_preview.md"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(out, encoding="utf-8")
    print(f"Wrote {out_path}")
    print("\n--- Preview (first 120 lines) ---\n")
    for i, line in enumerate(out.splitlines()):
        if i >= 120:
            print(f"... ({len(out.splitlines()) - 120} more lines)")
            break
        print(line)
    return 0

if __name__ == "__main__":
    sys.exit(main())
