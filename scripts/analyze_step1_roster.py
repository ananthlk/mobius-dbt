#!/usr/bin/env python3
"""
Analyze Step 1 (roster list) results from b0_roster_list_fl.

Env:
  BQ_PROJECT (default: mobius-os-dev)
  BQ_MARTS_MEDICAID_DATASET (default: mobius_medicaid_npi_dev)
"""

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
table = f"`{project}.{dataset}.b0_roster_list_fl`"


def run_analysis():
    client = bigquery.Client(project=project)

    # 1) Overall counts
    q1 = f"""
    SELECT
      count(*) as total_rows,
      count(distinct org_id) as distinct_orgs,
      count(distinct sub_org_id) as distinct_sub_orgs,
      count(distinct npi) as distinct_npis,
      countif(source_type = 'address') as address_based_rows,
      countif(source_type = 'billing_npi') as billing_based_rows
    FROM {table}
    """
    r1 = next(client.query(q1).result())

    # 2) Top 10 orgs by member count
    q2 = f"""
    SELECT org_id, count(*) as member_count
    FROM {table}
    GROUP BY org_id
    ORDER BY member_count DESC
    LIMIT 10
    """
    r2 = list(client.query(q2).result())

    # 3) Associated members distribution (sample of group sizes)
    q3 = f"""
    SELECT
      array_length(associated_member_npis) as assoc_size,
      count(*) as row_count
    FROM {table}
    WHERE associated_member_npis IS NOT NULL
    GROUP BY 1
    ORDER BY 1
    LIMIT 20
    """
    r3 = list(client.query(q3).result())

    # 4) Source type summary
    q4 = f"""
    SELECT source_type, count(*) as row_count, count(distinct npi) as distinct_npis
    FROM {table}
    GROUP BY source_type
    """
    r4 = list(client.query(q4).result())

    # 5) Facility vs non-facility breakdown (by org_id)
    # entity_type_code: 1 = individual, 2 = organization
    nppes = f"`{project}.{dataset}.nppes_fl`"
    q5 = f"""
    SELECT
      coalesce(cast(n.entity_type_code as string), 'unknown') as entity_type,
      case
        when cast(n.entity_type_code as string) = '2' then 'facility'
        when cast(n.entity_type_code as string) = '1' then 'individual'
        else 'unknown'
      end as org_type,
      count(*) as row_count,
      count(distinct r.org_id) as distinct_orgs,
      count(distinct r.npi) as distinct_members
    FROM {table} r
    LEFT JOIN {nppes} n ON n.npi = r.org_id
    GROUP BY 1, 2
    ORDER BY 3 DESC
    """
    r5 = list(client.query(q5).result())

    # 6) Facility vs non-facility by source_type
    q6 = f"""
    SELECT
      r.source_type,
      case
        when cast(n.entity_type_code as string) = '2' then 'facility'
        when cast(n.entity_type_code as string) = '1' then 'individual'
        else 'unknown'
      end as org_type,
      count(*) as row_count,
      count(distinct r.org_id) as distinct_orgs
    FROM {table} r
    LEFT JOIN {nppes} n ON n.npi = r.org_id
    GROUP BY 1, 2
    ORDER BY 1, 3 DESC
    """
    r6 = list(client.query(q6).result())

    return {
        "overall": {
            "total_rows": r1.total_rows,
            "distinct_orgs": r1.distinct_orgs,
            "distinct_sub_orgs": r1.distinct_sub_orgs,
            "distinct_npis": r1.distinct_npis,
            "address_based_rows": r1.address_based_rows,
            "billing_based_rows": r1.billing_based_rows,
        },
        "top_orgs": [{"org_id": r.org_id, "member_count": r.member_count} for r in r2],
        "assoc_size_dist": [{"assoc_size": r.assoc_size, "row_count": r.row_count} for r in r3],
        "by_source": [{"source_type": r.source_type, "row_count": r.row_count, "distinct_npis": r.distinct_npis} for r in r4],
        "facility_vs_nonfacility": [
            {"entity_type": r.entity_type, "org_type": r.org_type, "row_count": r.row_count, "distinct_orgs": r.distinct_orgs, "distinct_members": r.distinct_members}
            for r in r5
        ],
        "facility_by_source": [
            {"source_type": r.source_type, "org_type": r.org_type, "row_count": r.row_count, "distinct_orgs": r.distinct_orgs}
            for r in r6
        ],
    }


if __name__ == "__main__":
    d = run_analysis()
    print(json.dumps(d, indent=2))
