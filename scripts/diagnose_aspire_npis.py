#!/usr/bin/env python3
"""
Diagnose why Aspire has 0 NPIs in the report.
Checks bh_roster for org_name LIKE '%Aspire Health Partners%'.
"""
import os
import sys
from pathlib import Path

for _ in (Path(__file__).resolve().parents[2] / "mobius-config",):
    if _.exists():
        sys.path.insert(0, str(_))
        try:
            from env_helper import load_env
            load_env(Path(__file__).resolve().parents[1])
            break
        except Exception:
            pass

def main():
    from google.cloud import bigquery
    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    dataset = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")
    client = bigquery.Client(project=project)
    table = f"`{project}.{dataset}.bh_roster`"

    # 1. Total rows for Aspire
    q1 = f"""
    SELECT count(*) as total_rows,
           count(distinct concat(org_npi, '|', site_address_line_1, '|', site_city, '|', site_state, '|', site_zip, '|', coalesce(site_zip9,''))) as distinct_locations,
           count(distinct servicing_npi) as distinct_servicing_npis,
           countif(servicing_npi is not null and trim(cast(servicing_npi as string)) != '') as rows_with_servicing_npi
    FROM {table}
    WHERE LOWER(trim(coalesce(org_name,''))) LIKE '%aspire health partners%'
    """
    r1 = list(client.query(q1).result())[0]
    print("bh_roster for Aspire Health Partners:")
    print(f"  total_rows: {r1.total_rows}")
    print(f"  distinct_locations: {r1.distinct_locations}")
    print(f"  distinct_servicing_npis: {r1.distinct_servicing_npis}")
    print(f"  rows_with_servicing_npi: {r1.rows_with_servicing_npi}")

    # 2. Sample org_npi and org_name
    q2 = f"""
    SELECT distinct org_npi, org_name
    FROM {table}
    WHERE LOWER(trim(coalesce(org_name,''))) LIKE '%aspire health partners%'
    LIMIT 5
    """
    print("\nOrg NPIs / names:")
    for r in client.query(q2).result():
        print(f"  {r.org_npi} | {r.org_name}")

    # 3. Rows by source_type
    q3 = f"""
    SELECT source_type, count(*) as cnt
    FROM {table}
    WHERE LOWER(trim(coalesce(org_name,''))) LIKE '%aspire health partners%'
    GROUP BY source_type
    """
    print("\nRows by source_type:")
    for r in client.query(q3).result():
        print(f"  {r.source_type}: {r.cnt}")

    # 4. Raw row sample - check site_zip, site_zip9
    q4a = f"""
    SELECT org_npi, site_address_line_1, site_city, site_state, site_zip, site_zip9, servicing_npi
    FROM {table}
    WHERE LOWER(trim(coalesce(org_name,''))) LIKE '%aspire health partners%'
    LIMIT 2
    """
    print("\nRaw row sample (site_zip, site_zip9):")
    for r in client.query(q4a).result():
        print(f"  org={r.org_npi} zip={r.site_zip!r} zip9={r.site_zip9!r} svc={r.servicing_npi}")

    # 5. Location_ids (Python _location_id formula: sha256(org_npi|addr|city|state|zip|zip9)[:16])
    import hashlib
    def loc_id(o, a, c, s, z, z9):
        raw = "|".join(str(x) if x else "" for x in (o, a, c, s, z, z9))
        return hashlib.sha256(raw.encode()).hexdigest()[:16]

    q4 = f"""
    SELECT distinct org_npi, site_address_line_1, site_city, site_state, site_zip, site_zip9
    FROM {table}
    WHERE LOWER(trim(coalesce(org_name,''))) LIKE '%aspire health partners%'
    """
    print("\nDistinct locations (with computed location_id):")
    for r in client.query(q4).result():
        lid = loc_id(r.org_npi, r.site_address_line_1, r.site_city, r.site_state, r.site_zip, r.site_zip9)
        print(f"  {lid} | {r.org_npi} | {r.site_address_line_1}, {r.site_city} {r.site_zip}")

    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "mobius-skills" / "provider-roster-credentialing"))
    from app.core import get_locations, get_npis_per_location

    # 6. get_locations first (needed for loc_ids)
    locs = get_locations(client, "Aspire Health Partners", project, dataset, state_filter="FL")
    loc_ids = [loc["location_id"] for loc in locs]

    # 7. Manually compute location_ids from first 5 rows and compare
    q6 = f"""
    SELECT org_npi, site_address_line_1, site_city, site_state, site_zip, site_zip9
    FROM {table}
    WHERE LOWER(trim(coalesce(org_name,''))) LIKE '%aspire health partners%'
    LIMIT 5
    """
    print("\nManually compute loc_id for first 5 rows:")
    for r in client.query(q6).result():
        lid = loc_id(
            str(r.org_npi) if r.org_npi else "",
            str(r.site_address_line_1) if r.site_address_line_1 else "",
            str(r.site_city) if r.site_city else "",
            str(r.site_state) if r.site_state else "",
            str(r.site_zip) if r.site_zip is not None else "",
            str(r.site_zip9) if r.site_zip9 is not None else "",
        )
        print(f"  {lid} in loc_ids? {lid in loc_ids}")

    # 8. Run the exact query get_npis_per_location uses
    q8 = f"""
    SELECT org_npi, site_address_line_1, site_city, site_state, site_zip, site_zip9, servicing_npi
    FROM {table}
    WHERE LOWER(TRIM(COALESCE(org_name, ''))) LIKE LOWER('%Aspire Health Partners%')
      AND (UPPER(TRIM(COALESCE(site_state, ''))) IN ('FL', 'FLORIDA'))
    ORDER BY org_npi, site_address_line_1, site_city, site_state, servicing_npi
    """
    rows8 = list(client.query(q8).result())
    print(f"\nQuery rows returned: {len(rows8)}")
    if rows8:
        r0 = rows8[0]
        from app.core import _location_id
        lid0 = _location_id(
            str(r0.org_npi) if r0.org_npi else "",
            str(r0.site_address_line_1) if r0.site_address_line_1 else "",
            str(r0.site_city) if r0.site_city else "",
            str(r0.site_state) if r0.site_state else "",
            str(r0.site_zip) if r0.site_zip is not None else "",
            str(r0.site_zip9) if r0.site_zip9 is not None else "",
        )
        print(f"  First row loc_id: {lid0} in loc_ids? {lid0 in loc_ids}")

    # 9. Simulate get_npis_per_location with L1 location_ids
    npis_by_loc = get_npis_per_location(
        client, "Aspire Health Partners", loc_ids, project, dataset, None, state_filter="FL"
    )
    print("\nget_npis_per_location with L1 location_ids only:")
    print(f"  location_ids passed: {loc_ids}")
    print(f"  keys returned: {list(npis_by_loc.keys())}")
    for lid, nlist in npis_by_loc.items():
        print(f"  {lid}: {len(nlist)} NPIs")

    # 10. get_locations summary
    print("\nget_locations returns (location_ids):")
    for loc in locs:
        print(f"  {loc['location_id']} | {loc['org_npi']} | {loc['site_address_line_1']}, {loc['site_city']} {loc['site_zip']}")


if __name__ == "__main__":
    main()
