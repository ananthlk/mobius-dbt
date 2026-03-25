#!/usr/bin/env bash
# Create the Medicaid NPI BigQuery datasets if missing.
# Use when landing_medicaid_npi_dev (or your BQ_LANDING_MEDICAID_DATASET) is missing.
#
# Usage:
#   BQ_PROJECT=your-project ./scripts/ensure_medicaid_datasets.sh
#   Or: source .env && ./scripts/ensure_medicaid_datasets.sh

set -e
BQ_PROJECT="${BQ_PROJECT:-mobius-os-dev}"
BQ_LOCATION="${BQ_LOCATION:-US}"
BQ_LANDING="${BQ_LANDING_MEDICAID_DATASET:-landing_medicaid_npi_dev}"
BQ_MARTS="${BQ_MARTS_MEDICAID_DATASET:-mobius_medicaid_npi_dev}"

echo "Project: $BQ_PROJECT"
echo "Landing dataset: $BQ_LANDING"
echo "Marts dataset:   $BQ_MARTS"
echo ""

for ds in "$BQ_LANDING" "$BQ_MARTS"; do
  if bq ls -d --project_id="$BQ_PROJECT" "$ds" &>/dev/null; then
    echo "  $ds already exists."
  else
    echo "  Creating $ds ..."
    bq mk --project_id="$BQ_PROJECT" --dataset --location="$BQ_LOCATION" "${BQ_PROJECT}:${ds}"
    echo "  Created $ds"
  fi
done

echo ""
echo "Done. Create tables with: python scripts/create_medicaid_infra.py"
echo "Then load data (PML, TML, DOGE, NUCC) and run: dbt run --select marts.medicaid_npi"
