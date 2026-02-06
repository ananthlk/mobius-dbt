#!/usr/bin/env bash
# Create BigQuery datasets for MOBIUS-DBT: parallel envs (dev, staging, prod).
# Requires: bq CLI and auth (gcloud auth application-default login).
#
# Creates:
#   landing_rag_dev, landing_rag_staging, landing_rag_prod  (ingest writes rag_published_embeddings)
#   mobius_rag_dev, mobius_rag_staging, mobius_rag_prod      (dbt writes published_rag_embeddings; sync writes sync_runs)
#
# After this, run scripts/create_env_tables.sh to create the tables in each dataset.

set -e
BQ_PROJECT="${BQ_PROJECT:-mobiusos-new}"
BQ_LOCATION="${BQ_LOCATION:-US}"

echo "Creating datasets in project: $BQ_PROJECT (location: $BQ_LOCATION)"

for env in dev staging prod; do
  echo "  Creating landing_rag_${env}..."
  bq mk --project_id="$BQ_PROJECT" --dataset --location="$BQ_LOCATION" "${BQ_PROJECT}:landing_rag_${env}" 2>/dev/null || true
  echo "  Creating mobius_rag_${env}..."
  bq mk --project_id="$BQ_PROJECT" --dataset --location="$BQ_LOCATION" "${BQ_PROJECT}:mobius_rag_${env}" 2>/dev/null || true
done

echo "Done. Next: ./scripts/create_env_tables.sh to create tables in each dataset."
echo "Then: export BQ_PROJECT=$BQ_PROJECT BQ_DATASET=mobius_rag_dev BQ_LANDING_DATASET=landing_rag_dev && dbt run"
