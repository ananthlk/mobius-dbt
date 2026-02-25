#!/usr/bin/env bash
# Run FL Medicaid NPI pipeline: create infra → upload DOGE (optional) → seed TML/PML → load from GCS → dbt run.
#
# Env vars: BQ_PROJECT, GCS_MEDICAID_BUCKET, BQ_LANDING_MEDICAID_DATASET, BQ_MARTS_MEDICAID_DATASET
#           DOGE_LOCAL_PATH (optional) - if set, uploads local DOGE to GCS before load
# Example: BQ_PROJECT=mobius-os-dev DOGE_LOCAL_PATH=/path/to/doge.csv ./scripts/load_medicaid_and_dbt_run.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Load .env if present
[[ -f .env ]] && set -a && source .env && set +a

BQ_PROJECT="${BQ_PROJECT:-mobius-os-dev}"
GCS_BUCKET="${GCS_MEDICAID_BUCKET:-${BQ_PROJECT}-fl-medicaid-npi-raw}"
BQ_LANDING="${BQ_LANDING_MEDICAID_DATASET:-landing_medicaid_npi_dev}"
BQ_MARTS="${BQ_MARTS_MEDICAID_DATASET:-mobius_medicaid_npi_dev}"

export BQ_PROJECT GCS_MEDICAID_BUCKET="$GCS_BUCKET" BQ_LANDING_MEDICAID_DATASET="$BQ_LANDING" BQ_MARTS_MEDICAID_DATASET="$BQ_MARTS"

echo "=== FL Medicaid NPI pipeline ==="
echo "  BQ_PROJECT=$BQ_PROJECT"
echo "  GCS_MEDICAID_BUCKET=$GCS_BUCKET"
echo "  BQ_LANDING=$BQ_LANDING"
echo "  BQ_MARTS=$BQ_MARTS"
echo ""

echo "=== 0. Create GCS bucket and BigQuery infra ==="
GCP_PROJECT="$BQ_PROJECT" BQ_PROJECT="$BQ_PROJECT" ./scripts/create_gcs_medicaid_bucket.sh 2>/dev/null || true
BQ_PROJECT="$BQ_PROJECT" uv run python scripts/create_medicaid_infra.py 2>/dev/null || true
echo ""

echo "=== 1. Upload DOGE to GCS (if DOGE_LOCAL_PATH set) ==="
if [[ -n "${DOGE_LOCAL_PATH}" ]] && [[ -f "${DOGE_LOCAL_PATH}" ]]; then
  DOGE_LOCAL_PATH="$DOGE_LOCAL_PATH" uv run python scripts/upload_doge_to_gcs.py
else
  echo "  Skipped (set DOGE_LOCAL_PATH to local DOGE CSV to upload)"
fi
echo ""

echo "=== 2. Seed TML and PML from NPPES ==="
uv run python scripts/seed_medicaid_from_bq.py
echo ""

echo "=== 3. Load DOGE from GCS to BigQuery ==="
uv run python scripts/load_medicaid_from_gcs.py
echo ""

echo "=== 4. dbt run (medicaid_npi) ==="
export BQ_LANDING_MEDICAID_DATASET="$BQ_LANDING"
export BQ_MARTS_MEDICAID_DATASET="$BQ_MARTS"
dbt run --select nppes_providers medicaid_provider_ids fl_medicaid_taxonomy billing_patterns
echo ""

echo "=== 5. dbt test (medicaid_npi) ==="
dbt test --select nppes_providers medicaid_provider_ids fl_medicaid_taxonomy billing_patterns
echo ""

echo "Done. Mart tables in ${BQ_PROJECT}.${BQ_MARTS}"
