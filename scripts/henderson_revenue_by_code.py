#!/usr/bin/env python3
"""Henderson: biggest codes by revenue, average rate per code, assumed beneficiaries."""
import csv
import os
import sys
from pathlib import Path
from collections import defaultdict

_repo = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_repo / "mobius-config"))
sys.path.insert(0, str(_repo / "mobius-skills" / "provider-roster-credentialing"))
try:
    from env_helper import load_env
    load_env(_repo / "mobius-dbt")
except Exception:
    pass

def main():
    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    marts = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")
    invalid_path = _repo / "mobius-dbt/reports/Henderson/20260304_2355/provider_roster_credentialing_20260304_2355_invalid_combos.csv"
    if not invalid_path.exists():
        invalid_path = _repo / "mobius-dbt/reports/Henderson/20260304_2347/provider_roster_credentialing_20260304_2347_invalid_combos.csv"
    if not invalid_path.exists():
        print("No Henderson invalid_combos.csv found")
        return

    # Count invalid combos per taxonomy (Henderson)
    count_by_tax: dict[str, int] = defaultdict(int)
    with open(invalid_path) as f:
        for row in csv.DictReader(f):
            t = (row.get("provider_taxonomy_code") or "").strip()
            if t:
                count_by_tax[t] += 1

    client = None
    try:
        from google.cloud import bigquery
        client = bigquery.Client(project=project)
    except Exception as e:
        print(f"BigQuery not available: {e}")

    # Try dbt taxonomy rates (per-beneficiary + beneficiaries per provider)
    rates_table = f"`{project}.{marts}.fl_medicaid_taxonomy_revenue_rates`"
    tax_list = ",".join(repr(t) for t in count_by_tax.keys())
    q_rates = f"""
    SELECT provider_taxonomy_code,
           revenue_per_beneficiary_avg,
           revenue_per_beneficiary_p50,
           beneficiaries_per_provider_median
    FROM {rates_table}
    WHERE provider_taxonomy_code IN ({tax_list})
    """
    rate_per_tax: dict[str, dict] = {}
    if client:
        try:
            rows = list(client.query(q_rates).result())
            for r in rows:
                tax = str(r.get("provider_taxonomy_code") or "").strip()
                rate_per_tax[tax] = {
                    "revenue_per_beneficiary_avg": float(r.get("revenue_per_beneficiary_avg") or 0),
                    "revenue_per_beneficiary_p50": float(r.get("revenue_per_beneficiary_p50") or 0),
                    "beneficiaries_per_provider_median": float(r.get("beneficiaries_per_provider_median") or 0),
                }
        except Exception as e:
            print(f"fl_medicaid_taxonomy_revenue_rates not found or error: {e}")
            print("Run: dbt run --select fl_medicaid_taxonomy_revenue_rates\n")

    # Build revenue by taxonomy: count * (beneficiaries_median * revenue_per_ben)
    if rate_per_tax:
        rev_by_tax = []
        for tax, cnt in count_by_tax.items():
            r = rate_per_tax.get(tax)
            if not r or r["beneficiaries_per_provider_median"] <= 0 or r["revenue_per_beneficiary_p50"] <= 0:
                continue
            ben_med = r["beneficiaries_per_provider_median"]
            rev_per_ben = r["revenue_per_beneficiary_p50"]
            rev = cnt * ben_med * rev_per_ben
            rev_by_tax.append((tax, cnt, ben_med, rev_per_ben, rev))
        rev_by_tax.sort(key=lambda x: -x[4])
        total_rev = sum(x[4] for x in rev_by_tax)
        total_combos = sum(x[1] for x in rev_by_tax)
        total_assumed_bens = sum(x[1] * x[2] for x in rev_by_tax)
        n_codes = len(rev_by_tax)
        avg_rate_per_code = total_rev / n_codes if n_codes else 0
        avg_ben_per_combo = total_assumed_bens / total_combos if total_combos else 0

        print("Henderson – revenue from taxonomy rates (dbt fl_medicaid_taxonomy_revenue_rates)\n")
        print("Assumptions:")
        print(f"  Assumed beneficiaries per provider: state median by taxonomy (FL DOGE 2024)")
        print(f"  Revenue per beneficiary: state p50 by taxonomy")
        print(f"  Total invalid combos: {total_combos}")
        print(f"  Total assumed beneficiaries (across all invalid combos): {total_assumed_bens:,.0f}")
        print(f"  Average assumed beneficiaries per invalid combo: {avg_ben_per_combo:,.1f}")
        print()
        print("Average rate per code (mean revenue at risk per taxonomy):")
        print(f"  ${avg_rate_per_code:,.0f}")
        print()
        print("Top 15 codes by revenue at risk:")
        print(f"  {'Taxonomy':<18} {'Combos':>8} {'Ben/Prov':>10} {'$/Ben':>12} {'Revenue':>14}")
        print("  " + "-" * 64)
        for tax, cnt, ben_med, rev_per_ben, rev in rev_by_tax[:15]:
            print(f"  {tax:<18} {cnt:>8} {ben_med:>10.1f} ${rev_per_ben:>10,.0f} ${rev:>12,.0f}")
        print("  " + "-" * 64)
        print(f"  {'(all codes)':<18} {total_combos:>8} {'(varies)':>10} {'(varies)':>12} ${total_rev:>12,.0f}")
    else:
        # Fallback: use state run rate ($/physician) from Python
        sys.path.insert(0, str(_repo / "mobius-skills" / "provider-roster-credentialing"))
        from app.core import get_run_rate_by_taxonomy_state
        if client:
            landing = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")
            state_rates = get_run_rate_by_taxonomy_state(client, project, marts, landing, state="FL", year=2024)
            rev_by_tax = []
            for tax, cnt in count_by_tax.items():
                rate = state_rates.get(tax, 0)
                if rate <= 0:
                    continue
                rev = cnt * rate
                rev_by_tax.append((tax, cnt, rate, rev))
            rev_by_tax.sort(key=lambda x: -x[3])
            total_rev = sum(x[3] for x in rev_by_tax)
            n_codes = len([x for x in rev_by_tax if x[3] > 0])
            avg_rate_per_code = total_rev / n_codes if n_codes else 0
            print("Henderson – revenue from state run rate ($/physician); no beneficiary assumption in this path\n")
            print("Average rate per code (mean revenue at risk per taxonomy):")
            print(f"  ${avg_rate_per_code:,.0f}")
            print("\nAssumed beneficiaries: not used in this run (state $/physician applied per combo).")
            print("For per-beneficiary assumptions and beneficiaries per provider, run dbt and use bh_roster_revenue_impact.\n")
            print("Top 15 codes by revenue at risk:")
            print(f"  {'Taxonomy':<18} {'Combos':>8} {'$/physician':>14} {'Revenue':>14}")
            print("  " + "-" * 56)
            for tax, cnt, rate, rev in rev_by_tax[:15]:
                print(f"  {tax:<18} {cnt:>8} ${rate:>12,.0f} ${rev:>12,.0f}")
        else:
            print("Top codes by invalid combo count (revenue/rate need BQ):")
            for tax, cnt in sorted(count_by_tax.items(), key=lambda x: -x[1])[:15]:
                print(f"  {tax}: {cnt} combos")

if __name__ == "__main__":
    main()
