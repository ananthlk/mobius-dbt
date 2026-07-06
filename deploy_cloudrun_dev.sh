#!/usr/bin/env bash
# Deploy mobius-dbt-ui to Cloud Run in mobius-os-dev.
#
# Mirror of the staging config for mobius-staging-mobius, with dev
# project/instance/DB-user substitutions.
#
# Prereqs:
#   * Secret Manager: db-password (used for POSTGRES_PASSWORD — dev
#     uses the built-in postgres user, not staging's mobius_app)
#   * BQ datasets mobius_rag and landing_rag already exist in
#     mobius-os-dev (confirmed 2026-04-23)
#
# Usage:
#   ./deploy_cloudrun_dev.sh
#   TAG=v1-foo ./deploy_cloudrun_dev.sh
set -euo pipefail

PROJECT_ID="mobius-os-dev"
REGION="us-central1"
CLOUD_SQL_INSTANCE="mobius-platform-dev-db"
CLOUD_SQL_CONNECTION="${PROJECT_ID}:${REGION}:${CLOUD_SQL_INSTANCE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo "manual-$(date +%s)")}"
REPO="us-central1-docker.pkg.dev/${PROJECT_ID}/mobius-dbt"
IMAGE="${REPO}/ui:${TAG}"

echo "=============================================================="
echo "Deploy mobius-dbt-ui → ${PROJECT_ID} (tag=${TAG})"
echo "=============================================================="

# 1. Ensure Artifact Registry repo
gcloud artifacts repositories describe mobius-dbt \
  --project="$PROJECT_ID" --location="$REGION" >/dev/null 2>&1 || \
  gcloud artifacts repositories create mobius-dbt \
    --project="$PROJECT_ID" --location="$REGION" \
    --repository-format=docker --description="Mobius dbt UI images" --quiet

# 2. Build
echo "--- building $IMAGE ---"
gcloud builds submit --project="$PROJECT_ID" --tag="$IMAGE" .

# 3. Deploy
echo "--- deploying mobius-dbt-ui ---"
gcloud run deploy mobius-dbt-ui \
  --image="$IMAGE" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --platform=managed \
  --allow-unauthenticated \
  --memory=2Gi \
  --cpu=2 \
  --timeout=3600 \
  --min-instances=0 \
  --max-instances=3 \
  --add-cloudsql-instances="$CLOUD_SQL_CONNECTION" \
  --service-account="mobius-platform-dev@${PROJECT_ID}.iam.gserviceaccount.com" \
  --set-env-vars="POSTGRES_HOST=/cloudsql/${CLOUD_SQL_CONNECTION}" \
  --set-env-vars="POSTGRES_PORT=5432" \
  --set-env-vars="POSTGRES_DB=mobius_rag" \
  --set-env-vars="POSTGRES_USER=postgres" \
  --set-env-vars="BQ_PROJECT=${PROJECT_ID}" \
  --set-env-vars="BQ_DATASET=mobius_rag" \
  --set-env-vars="BQ_LANDING_DATASET=landing_rag" \
  --set-env-vars="VERTEX_PROJECT=${PROJECT_ID}" \
  --set-env-vars="VERTEX_REGION=${REGION}" \
  --set-env-vars="GCS_BUCKET=mobius-rag-uploads-dev" \
  --set-secrets="POSTGRES_PASSWORD=db-password:latest" \
  --quiet

URL=$(gcloud run services describe mobius-dbt-ui --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)')
echo ""
echo "=============================================================="
echo "Deploy complete: $URL"
echo ""
echo "Smoke: curl ${URL}/config"
