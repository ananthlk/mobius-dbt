#!/usr/bin/env bash
# One-environment setup for FL Medicaid NPI pipeline (B0–B6).
# Run from mobius-dbt: ./scripts/setup_medicaid_npi_env.sh
#
# 1. Loads .env (if present) and sets BQ + Medicaid dataset vars
# 2. Ensures Python venv and deps (dbt-bigquery, google-cloud-bigquery)
# 3. Creates BigQuery datasets (landing_medicaid_npi_*, mobius_medicaid_npi_*) if needed
# 4. dbt seed (facility taxonomy, etc.)
# 5. dbt run for Medicaid NPI + B6
# 6. Optionally generates B6 report for "Aspire Behavioral Health"
#
# Prereqs: gcloud auth application-default login (or GOOGLE_APPLICATION_CREDENTIALS)

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOBIUS_DBT="$(cd "$SCRIPT_DIR/.." && pwd)"
MOBIUS_ROOT="$(cd "$MOBIUS_DBT/.." && pwd)"

# Load .env if present
if [[ -f "$MOBIUS_DBT/.env" ]]; then
  set -a
  source "$MOBIUS_DBT/.env"
  set +a
  echo "Loaded $MOBIUS_DBT/.env"
fi

export BQ_PROJECT="${BQ_PROJECT:-mobius-os-dev}"
export BQ_MARTS_MEDICAID_DATASET="${BQ_MARTS_MEDICAID_DATASET:-mobius_medicaid_npi_dev}"
export BQ_LANDING_MEDICAID_DATASET="${BQ_LANDING_MEDICAID_DATASET:-landing_medicaid_npi_dev}"
export BQ_DATASET="${BQ_DATASET:-mobius_rag}"
export BQ_LOCATION="${BQ_LOCATION:-US}"

echo "BQ_PROJECT=$BQ_PROJECT"
echo "BQ_MARTS_MEDICAID_DATASET=$BQ_MARTS_MEDICAID_DATASET"
echo "BQ_LANDING_MEDICAID_DATASET=$BQ_LANDING_MEDICAID_DATASET"
echo ""

# Venv: prefer mobius-dbt/.venv, then workspace .venv
VENV=""
if [[ -d "$MOBIUS_DBT/.venv" ]]; then
  VENV="$MOBIUS_DBT/.venv"
elif [[ -d "$MOBIUS_ROOT/.venv" ]]; then
  VENV="$MOBIUS_ROOT/.venv"
fi

if [[ -z "$VENV" ]]; then
  echo "Creating venv in $MOBIUS_DBT/.venv ..."
  python3 -m venv "$MOBIUS_DBT/.venv"
  VENV="$MOBIUS_DBT/.venv"
fi

echo "Using venv: $VENV"
source "$VENV/bin/activate"

if ! python -c "import dbt" 2>/dev/null; then
  echo "Installing dependencies (dbt-bigquery, google-cloud-bigquery, ...) ..."
  pip install -q -r "$MOBIUS_DBT/requirements.txt"
fi

cd "$MOBIUS_DBT"

# BigQuery datasets
echo ""
echo "Creating BigQuery datasets (if missing) ..."
bq mk --project_id="$BQ_PROJECT" --dataset --location="$BQ_LOCATION" "${BQ_PROJECT}:${BQ_LANDING_MEDICAID_DATASET}" 2>/dev/null || true
bq mk --project_id="$BQ_PROJECT" --dataset --location="$BQ_LOCATION" "${BQ_PROJECT}:${BQ_MARTS_MEDICAID_DATASET}" 2>/dev/null || true
echo "  $BQ_LANDING_MEDICAID_DATASET, $BQ_MARTS_MEDICAID_DATASET"

# dbt seed (facility taxonomy, etc.)
echo ""
echo "Running dbt seed ..."
dbt seed

# dbt run: all models needed for B6 (B0–B5 + B6)
echo ""
echo "Running dbt run --select +b6_integrated_report_fl ..."
dbt run --select +b6_integrated_report_fl

# Optional: B6 report for Aspire Behavioral Health (skip prompt if not a TTY)
if [[ -t 0 ]]; then
  read -r -p "Generate B6 report for 'Aspire Behavioral Health'? [y/N] " reply
  if [[ "$reply" =~ ^[yY] ]]; then
    python scripts/generate_b6_report.py --name "Aspire Behavioral Health" || true
  fi
else
  echo "Skipping B6 report prompt (non-interactive). Run: python scripts/generate_b6_report.py --name \"Aspire Behavioral Health\""
fi

echo ""
echo "Done. One environment ready: BQ $BQ_PROJECT / $BQ_MARTS_MEDICAID_DATASET"
echo "  Query B6: SELECT * FROM \`$BQ_PROJECT.$BQ_MARTS_MEDICAID_DATASET.b6_integrated_report_fl\` WHERE org_id = '...' OR npi = '...' OR site_id = '...'"
echo "  Report script: python scripts/generate_b6_report.py --name \"Aspire Behavioral Health\" | --org_id ... | --npi ... | --site_id ..."
