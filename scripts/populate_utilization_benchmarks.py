#!/usr/bin/env python3
"""
Populate taxonomy_utilization_benchmarks table.

Benchmarks: claims_per_member, revenue_per_member, revenue_per_claim
by taxonomy_code at ZIP5, state, and national levels.

Run periodically (e.g. weekly). Table is read by Step 10 (potential revenue for missed NPIs).

Usage:
  cd mobius-dbt
  uv run python scripts/populate_utilization_benchmarks.py
  uv run python scripts/populate_utilization_benchmarks.py --period 2024 --state FL

Requires: stg_doge with billing_npi, servicing_npi, claim_count, total_paid, beneficiary_count, period_month, state
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

_repo = Path(__file__).resolve().parents[1]
for env_path in (_repo / "mobius-config" / ".env", _repo / ".env", _repo / "mobius-dbt" / ".env"):
    if env_path.exists():
        try:
            from dotenv import load_dotenv
            load_dotenv(env_path, override=False)
        except Exception:
            pass
        break

project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
landing = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")
marts = os.environ.get("BQ_MARTS_MEDICAID_DATASET", "mobius_medicaid_npi_dev")


def main() -> int:
    parser = argparse.ArgumentParser(description="Populate utilization benchmarks table")
    parser.add_argument("--period", default="2024", help="Year (e.g. 2024)")
    parser.add_argument("--state", default="FL", help="State filter for DOGE")
    parser.add_argument("--dry-run", action="store_true", help="Print query only")
    args = parser.parse_args()

    try:
        from google.cloud import bigquery
        bq = bigquery.Client(project=project)
    except Exception as e:
        print(f"BigQuery not available: {e}", file=sys.stderr)
        return 1

    table_doge = f"`{project}.{landing}.stg_doge`"
    table_out = f"`{project}.{marts}.taxonomy_utilization_benchmarks`"
    nppes = "bigquery-public-data.nppes.npi_raw"

    query = f"""
-- Utilization benchmarks by taxonomy and geography (ZIP5, state, national)
-- Run periodically; Step 10 reads from this table.
CREATE OR REPLACE TABLE {table_out} AS
WITH doge_base AS (
  SELECT
    TRIM(CAST(servicing_npi AS STRING)) AS servicing_npi,
    TRIM(CAST(COALESCE(state, 'FL') AS STRING)) AS state,
    SUM(COALESCE(claim_count, 0)) AS claim_count,
    SUM(COALESCE(total_paid, 0)) AS total_paid,
    SUM(COALESCE(beneficiary_count, 0)) AS beneficiary_count
  FROM {table_doge}
  WHERE servicing_npi IS NOT NULL
    AND TRIM(CAST(servicing_npi AS STRING)) != ''
    AND SUBSTR(SAFE_CAST(period_month AS STRING), 1, 4) = @period
    AND (state IS NULL OR UPPER(TRIM(CAST(state AS STRING))) = @state_filter)
  GROUP BY 1, 2
),
npi_geo AS (
  SELECT
    TRIM(CAST(n.npi AS STRING)) AS npi,
    SUBSTR(REGEXP_REPLACE(COALESCE(n.provider_business_practice_location_address_postal_code, ''), r'[^0-9]', ''), 1, 5) AS zip5,
    UPPER(TRIM(COALESCE(n.provider_business_practice_location_address_state_name, ''))) AS nppes_state,
    TRIM(CAST(n.healthcare_provider_taxonomy_code_1 AS STRING)) AS taxonomy_code
  FROM `{nppes}` n
  WHERE n.healthcare_provider_taxonomy_code_1 IS NOT NULL
    AND TRIM(CAST(n.healthcare_provider_taxonomy_code_1 AS STRING)) != ''
),
joined AS (
  SELECT
    d.servicing_npi,
    d.state,
    g.zip5,
    g.taxonomy_code,
    d.claim_count,
    d.total_paid,
    d.beneficiary_count
  FROM doge_base d
  INNER JOIN npi_geo g ON g.npi = d.servicing_npi
  WHERE d.beneficiary_count > 0
),
-- ZIP5 level
by_zip AS (
  SELECT
    taxonomy_code,
    'zip5' AS geography_type,
    zip5 AS geography_value,
    @period AS period,
    SUM(claim_count) AS claim_count,
    SUM(total_paid) AS total_revenue,
    SUM(beneficiary_count) AS member_count,
    SAFE_DIVIDE(SUM(claim_count), SUM(beneficiary_count)) AS claims_per_member,
    SAFE_DIVIDE(SUM(total_paid), SUM(beneficiary_count)) AS revenue_per_member,
    SAFE_DIVIDE(SUM(total_paid), NULLIF(SUM(claim_count), 0)) AS revenue_per_claim
  FROM joined
  WHERE LENGTH(zip5) = 5
  GROUP BY 1, 2, 3
  HAVING SUM(beneficiary_count) >= 5
),
-- State level
by_state AS (
  SELECT
    taxonomy_code,
    'state' AS geography_type,
    state AS geography_value,
    @period AS period,
    SUM(claim_count) AS claim_count,
    SUM(total_paid) AS total_revenue,
    SUM(beneficiary_count) AS member_count,
    SAFE_DIVIDE(SUM(claim_count), SUM(beneficiary_count)) AS claims_per_member,
    SAFE_DIVIDE(SUM(total_paid), SUM(beneficiary_count)) AS revenue_per_member,
    SAFE_DIVIDE(SUM(total_paid), NULLIF(SUM(claim_count), 0)) AS revenue_per_claim
  FROM joined
  WHERE state IS NOT NULL AND TRIM(state) != ''
  GROUP BY 1, 2, 3
  HAVING SUM(beneficiary_count) >= 10
),
-- National (all in joined)
by_national AS (
  SELECT
    taxonomy_code,
    'national' AS geography_type,
    'US' AS geography_value,
    @period AS period,
    SUM(claim_count) AS claim_count,
    SUM(total_paid) AS total_revenue,
    SUM(beneficiary_count) AS member_count,
    SAFE_DIVIDE(SUM(claim_count), SUM(beneficiary_count)) AS claims_per_member,
    SAFE_DIVIDE(SUM(total_paid), SUM(beneficiary_count)) AS revenue_per_member,
    SAFE_DIVIDE(SUM(total_paid), NULLIF(SUM(claim_count), 0)) AS revenue_per_claim
  FROM joined
  GROUP BY 1, 2, 3
  HAVING SUM(beneficiary_count) >= 20
)
SELECT * FROM by_zip
UNION ALL SELECT * FROM by_state
UNION ALL SELECT * FROM by_national
ORDER BY geography_type, geography_value, taxonomy_code
"""

    if args.dry_run:
        print(query.replace("@period", f"'{args.period}'").replace("@state_filter", f"'{args.state}'"))
        return 0

    try:
        from google.cloud.bigquery import QueryJobConfig, ScalarQueryParameter
        job_config = QueryJobConfig(query_parameters=[
            ScalarQueryParameter("period", "STRING", args.period),
            ScalarQueryParameter("state_filter", "STRING", args.state),
        ])
        job = bq.query(query, job_config=job_config)
        job.result()
        print(f"Created {table_out}")
        return 0
    except Exception as e:
        print(f"Failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
