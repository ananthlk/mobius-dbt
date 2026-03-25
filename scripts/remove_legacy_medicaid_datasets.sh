#!/usr/bin/env bash
# Remove legacy Medicaid NPI datasets that are not used by the pipeline.
# Canonical pair: landing_medicaid_npi_dev + mobius_medicaid_npi_dev (see docs/BIGQUERY_DATASETS.md).
#
# Usage: BQ_PROJECT=mobiusos-new ./scripts/remove_legacy_medicaid_datasets.sh
#        (or set BQ_PROJECT in .env and source it first)

set -e
BQ_PROJECT="${BQ_PROJECT:-mobiusos-new}"

for dataset in mobius_rag_landing_medicaid_npi_dev mobius_rag_mobius_medicaid_npi_dev; do
  if bq ls -d --project_id="$BQ_PROJECT" "$dataset" &>/dev/null; then
    echo "Removing ${BQ_PROJECT}:${dataset} ..."
    bq rm -r -f -d "${BQ_PROJECT}:${dataset}"
    echo "  Done."
  else
    echo "  ${dataset} not found in ${BQ_PROJECT}, skipping."
  fi
done
echo "Cleanup complete. Use landing_medicaid_npi_dev and mobius_medicaid_npi_dev only."
