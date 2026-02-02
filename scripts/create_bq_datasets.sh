#!/usr/bin/env bash
# Create BigQuery datasets for MOBIUS-DBT (project: mobiusos-new).
# Requires: bq CLI and auth (gcloud auth application-default login).

set -e
BQ_PROJECT="${BQ_PROJECT:-mobiusos-new}"
BQ_LOCATION="${BQ_LOCATION:-US}"

echo "Creating datasets in project: $BQ_PROJECT (location: $BQ_LOCATION)"

echo "  Creating landing_rag..."
bq mk --project_id="$BQ_PROJECT" --dataset --location="$BQ_LOCATION" "${BQ_PROJECT}:landing_rag"
echo "  Created landing_rag"

echo "  Creating mobius_rag..."
bq mk --project_id="$BQ_PROJECT" --dataset --location="$BQ_LOCATION" "${BQ_PROJECT}:mobius_rag"
echo "  Created mobius_rag"

echo "  Creating mobius_rag_dev..."
bq mk --project_id="$BQ_PROJECT" --dataset --location="$BQ_LOCATION" "${BQ_PROJECT}:mobius_rag_dev"
echo "  Created mobius_rag_dev"

echo "Done. Use: export BQ_PROJECT=$BQ_PROJECT BQ_DATASET=mobius_rag_dev && dbt run"
