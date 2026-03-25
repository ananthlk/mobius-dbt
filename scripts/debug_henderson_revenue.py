#!/usr/bin/env python3
"""Debug Henderson revenue: taxonomy coverage, state run rates, org run rates."""
import csv
import os
import sys
from pathlib import Path

_repo = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_repo / "mobius-config"))
sys.path.insert(0, str(_repo / "mobius-skills" / "provider-roster-credentialing"))
try:
    from env_helper import load_env
    load_env(_repo / "mobius-dbt")
except Exception:
    pass

def main():
    from google.cloud import bigquery
    from app.core import (
        get_run_rate_by_taxonomy_state,
        get_billing_run_rate_by_taxonomy_location,
        _compute_org_run_rates_by_taxonomy,
    )

    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    marts = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")
    landing = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")

    # Henderson 6 FL org_npis
    org_npis = {"1043880156", "1174113849", "1366454308", "1427226364", "1851961791", "1982979662"}

    # 1. Distinct taxonomies in Henderson invalid combos
    invalid_path = Path(__file__).parent.parent / "reports/Henderson/20260304_2347/provider_roster_credentialing_20260304_2347_invalid_combos.csv"
    henderson_taxonomies = set()
    with open(invalid_path) as f:
        r = csv.DictReader(f)
        for row in r:
            t = (row.get("provider_taxonomy_code") or "").strip()
            if t:
                henderson_taxonomies.add(t)
    print(f"1. Henderson invalid combos: {len(henderson_taxonomies)} distinct taxonomies")
    print(f"   Sample: {sorted(henderson_taxonomies)[:15]}...")
    print()

    # 2. State-wide run rates
    client = bigquery.Client(project=project)
    state_rates = get_run_rate_by_taxonomy_state(client, project, marts, landing, state="FL", year=2024)
    print(f"2. State-wide (FL) run rates: {len(state_rates)} taxonomies")
    if state_rates:
        sample = list(state_rates.items())[:10]
        for tax, rate in sample:
            print(f"   {tax}: ${rate:,.0f}")
        # Overlap with Henderson
        overlap = henderson_taxonomies & set(state_rates.keys())
        print(f"   Overlap with Henderson invalid combos: {len(overlap)} / {len(henderson_taxonomies)}")
        if not overlap:
            print("   NO OVERLAP - Henderson taxonomies not in state run rates!")
    else:
        print("   (empty - state query returned no rows)")
    print()

    # 3. Org-level run rates (from location-level)
    loc_rates = get_billing_run_rate_by_taxonomy_location(client, org_npis, project, marts, landing, year=2024)
    print(f"3. Org-level (location) run rates for 6 Henderson orgs: {len(loc_rates)} cells")
    if loc_rates:
        org_agg = _compute_org_run_rates_by_taxonomy(loc_rates)
        print(f"   Aggregated to (taxonomy, org) avg/high: {len(org_agg)} entries")
        for (t, o), (avg, high) in list(org_agg.items())[:5]:
            print(f"   {t} @ org {o}: avg=${avg:,.0f}, high=${high:,.0f}")
        overlap = henderson_taxonomies & {t for t, _ in org_agg.keys()}
        print(f"   Overlap with Henderson: {len(overlap)} / {len(henderson_taxonomies)}")
    else:
        print("   (empty - org has no DOGE billing for these taxonomies)")
    print()

    # 4. TML check: are Henderson taxonomies in stg_tml?
    tml_table = f"`{project}.{landing}.stg_tml`"
    tax_list = ",".join(repr(t) for t in henderson_taxonomies)
    q = f"SELECT taxonomy_code FROM {tml_table} WHERE TRIM(CAST(taxonomy_code AS STRING)) IN ({tax_list})"
    rows = list(client.query(q).result())
    in_tml = {str(r.get("taxonomy_code") or "").strip() for r in rows}
    print(f"4. TML (state-approved): {len(in_tml)} of {len(henderson_taxonomies)} Henderson taxonomies in stg_tml")
    not_in_tml = henderson_taxonomies - in_tml
    if not_in_tml:
        print(f"   NOT in TML: {sorted(not_in_tml)[:10]}...")
    print()

    # 5. Does DOGE have Henderson orgs as billing_npi at all?
    doge_table = f"`{project}.{landing}.stg_doge`"
    org_list = ",".join(repr(x) for x in org_npis)
    q5 = f"""
    SELECT billing_npi, COUNT(*) as rows_2024, SUM(COALESCE(total_paid,0)) as total_paid
    FROM {doge_table}
    WHERE billing_npi IN ({org_list})
      AND SUBSTR(SAFE_CAST(period_month AS STRING), 1, 4) = '2024'
    GROUP BY billing_npi
    """
    rows5 = list(client.query(q5).result())
    print("5. DOGE 2024: Henderson org_npis as billing_npi?")
    if rows5:
        for r in rows5:
            print(f"   {r.get('billing_npi')}: {r.get('rows_2024')} rows, ${float(r.get('total_paid') or 0):,.0f}")
    else:
        print("   NO rows - Henderson org NPIs never appear as billing_npi in DOGE 2024")
    # 5b. What about as servicing_npi?
    q5b = f"""
    SELECT servicing_npi, COUNT(*) as rows_2024, SUM(COALESCE(total_paid,0)) as total_paid
    FROM {doge_table}
    WHERE servicing_npi IN ({org_list})
      AND SUBSTR(SAFE_CAST(period_month AS STRING), 1, 4) = '2024'
    GROUP BY servicing_npi
    """
    rows5b = list(client.query(q5b).result())
    print("   Henderson org_npis as servicing_npi?")
    if rows5b:
        for r in rows5b:
            print(f"   {r.get('servicing_npi')}: {r.get('rows_2024')} rows, ${float(r.get('total_paid') or 0):,.0f}")
    else:
        print("   NO rows as servicing_npi either")
    # 5c. Sample of Henderson servicing NPIs (from roster) - do THEY appear in DOGE?
    servicing_sample = set()
    with open(invalid_path) as f:
        for i, row in enumerate(csv.DictReader(f)):
            if i >= 50:
                break
            servicing_sample.add((row.get("servicing_npi") or "").strip())
    servicing_sample = {x for x in servicing_sample if x}
    svc_list = ",".join(repr(x) for x in list(servicing_sample)[:20])
    q5c = f"""
    SELECT servicing_npi, billing_npi, SUM(COALESCE(total_paid,0)) as paid
    FROM {doge_table}
    WHERE servicing_npi IN ({svc_list})
      AND SUBSTR(SAFE_CAST(period_month AS STRING), 1, 4) = '2024'
    GROUP BY servicing_npi, billing_npi
    LIMIT 10
    """
    rows5c = list(client.query(q5c).result())
    print("   Sample Henderson servicing NPIs in DOGE (who bills for them)?")
    if rows5c:
        for r in rows5c:
            print(f"   servicing={r.get('servicing_npi')} billing={r.get('billing_npi')} paid=${float(r.get('paid') or 0):,.0f}")
    else:
        print("   None of the sampled servicing NPIs appear in DOGE 2024")

    print()
    print("DONE")

if __name__ == "__main__":
    main()
