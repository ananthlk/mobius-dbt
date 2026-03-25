#!/usr/bin/env bash
# Drop mobius_medicaid_npi_dev dataset and all its tables, then recreate an empty dataset.
# Use this to start fresh. Requires: bq CLI, gcloud auth.
#
# Env: BQ_PROJECT (default: mobius-os-dev), BQ_MARTS_MEDICAID_DATASET (default: mobius_medicaid_npi_dev)
#
# WARNING: This deletes all data in the dataset. Run only when you intend to rebuild from scratch.

set -e
BQ_PROJECT="${BQ_PROJECT:-mobius-os-dev}"
DATASET="${BQ_MARTS_MEDICAID_DATASET:-mobius_medicaid_npi_dev}"
BQ_LOCATION="${BQ_LOCATION:-US}"

echo "WARNING: This will DELETE the dataset ${BQ_PROJECT}:${DATASET} and all its tables."
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

echo "Dropping ${BQ_PROJECT}:${DATASET}..."
bq rm -r -f "${BQ_PROJECT}:${DATASET}" || true

echo "Creating empty ${BQ_PROJECT}:${DATASET}..."
bq mk --project_id="$BQ_PROJECT" --dataset --location="$BQ_LOCATION" "${BQ_PROJECT}:${DATASET}"

echo "Done. Dataset is empty. Re-enable medicaid_npi models in dbt_project.yml and run dbt when ready."
