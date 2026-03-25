#!/usr/bin/env python3
"""
Analyze Step 1 roster restricted to orgs with Medicaid spend >= min_spend.

Restricts to orgs where:
- Billing orgs: sum(total_paid) where billing_npi = org_id
- Address orgs: sum(total_paid) where servicing_npi in (members of that org)

Usage:
  python scripts/analyze_step1_roster_min_spend.py --min-spend 100000
"""

import argparse
import json
import os
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
    print("Install google-cloud-bigquery: pip install google-cloud-bigquery")
    raise

project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
dataset = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")
roster = f"`{project}.{dataset}.b0_roster_list_fl`"
pairs = f"`{project}.{dataset}.billing_servicing_pairs_fl`"
nppes = f"`{project}.{dataset}.nppes_fl`"


def run_analysis(min_spend: float = 100_000):
    client = bigquery.Client(project=project)

    # Roster filtered to orgs with total spend >= min_spend.
    # Billing orgs: aggregate by billing_npi. Address orgs: aggregate pairs by servicing_npi, join to roster, sum by org_id.
    base = f"""
    WITH     billing_spend_raw AS (
      SELECT billing_npi AS org_id, SUM(total_paid) AS total_paid
      FROM {pairs}
      GROUP BY 1
    ),
    billing_spend AS (
      SELECT org_id FROM billing_spend_raw WHERE total_paid >= {min_spend}
    ),
    servicing_spend AS (
      SELECT servicing_npi AS npi, SUM(total_paid) AS total_paid
      FROM {pairs}
      GROUP BY 1
    ),
    address_org_spend_raw AS (
      SELECT r.org_id, SUM(s.total_paid) AS total_paid
      FROM {roster} r
      JOIN servicing_spend s ON s.npi = r.npi
      WHERE r.source_type = 'address'
      GROUP BY r.org_id
    ),
    address_org_spend AS (
      SELECT org_id FROM address_org_spend_raw WHERE total_paid >= {min_spend}
    ),
    org_spend AS (
      SELECT org_id FROM billing_spend
      UNION DISTINCT
      SELECT org_id FROM address_org_spend
    ),
    filtered AS (
      SELECT r.* FROM {roster} r
      INNER JOIN org_spend s ON s.org_id = r.org_id
    )
    """

    # 1) Overall
    q1 = base + f"""
    SELECT
      count(*) AS total_rows,
      count(DISTINCT org_id) AS distinct_orgs,
      count(DISTINCT sub_org_id) AS distinct_sub_orgs,
      count(DISTINCT npi) AS distinct_npis,
      countif(source_type = 'address') AS address_based_rows,
      countif(source_type = 'billing_npi') AS billing_based_rows
    FROM filtered
    """
    r1 = next(client.query(q1).result())

    # 2) Facility vs individual (org_id)
    q2 = base + f"""
    SELECT
      CASE CAST(n.entity_type_code AS STRING)
        WHEN '2' THEN 'facility'
        WHEN '1' THEN 'individual'
        ELSE 'unknown'
      END AS org_type,
      count(*) AS row_count,
      count(DISTINCT r.org_id) AS distinct_orgs,
      count(DISTINCT r.npi) AS distinct_members
    FROM filtered r
    LEFT JOIN {nppes} n ON n.npi = r.org_id
    GROUP BY 1
    ORDER BY 2 DESC
    """
    r2 = list(client.query(q2).result())

    # 3) By source_type
    q3 = base + f"""
    SELECT source_type, count(*) AS row_count, count(DISTINCT npi) AS distinct_npis
    FROM filtered
    GROUP BY source_type
    """
    r3 = list(client.query(q3).result())

    # 4) Top 10 orgs by member count
    q4 = base + f"""
    SELECT org_id, count(*) AS member_count
    FROM filtered
    GROUP BY org_id
    ORDER BY member_count DESC
    LIMIT 10
    """
    r4 = list(client.query(q4).result())

    return {
        "min_spend": min_spend,
        "overall": {
            "total_rows": r1.total_rows,
            "distinct_orgs": r1.distinct_orgs,
            "distinct_sub_orgs": r1.distinct_sub_orgs,
            "distinct_npis": r1.distinct_npis,
            "address_based_rows": r1.address_based_rows,
            "billing_based_rows": r1.billing_based_rows,
        },
        "facility_vs_individual": [
            {"org_type": r.org_type, "row_count": r.row_count, "distinct_orgs": r.distinct_orgs, "distinct_members": r.distinct_members}
            for r in r2
        ],
        "by_source": [{"source_type": r.source_type, "row_count": r.row_count, "distinct_npis": r.distinct_npis} for r in r3],
        "top_orgs": [{"org_id": r.org_id, "member_count": r.member_count} for r in r4],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--min-spend", type=float, default=100_000)
    args = parser.parse_args()
    d = run_analysis(args.min_spend)
    print(json.dumps(d, indent=2))
