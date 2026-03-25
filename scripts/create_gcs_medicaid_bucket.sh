#!/usr/bin/env bash
# Create GCS bucket for FL Medicaid NPI raw extracted files.
# Requires: gsutil and auth (gcloud auth application-default login).
#
# Creates bucket: {project}-fl-medicaid-npi-raw with folder structure for PML, PPL, TML, NPPES, DOGE.
# Extraction jobs upload files here; load jobs read from here for BigQuery landing.

set -e
GCP_PROJECT="${GCP_PROJECT:-${BQ_PROJECT:-mobius-os-dev}}"
BUCKET_NAME="${GCP_PROJECT}-fl-medicaid-npi-raw"
LOCATION="${BQ_LOCATION:-US}"

echo "Creating GCS bucket: gs://${BUCKET_NAME} (project: ${GCP_PROJECT}, location: ${LOCATION})"

gsutil mb -p "$GCP_PROJECT" -l "$LOCATION" "gs://${BUCKET_NAME}" 2>/dev/null || echo "  Bucket may already exist."
gsutil ls "gs://${BUCKET_NAME}/" >/dev/null 2>&1 || true

echo "Creating folder structure (placeholder objects)..."
for folder in raw/pml raw/ppl raw/tml raw/nppes raw/doge raw/roster_uploads cleansed/roster_uploads; do
  echo "  gs://${BUCKET_NAME}/${folder}/"
  echo "" | gsutil cp - "gs://${BUCKET_NAME}/${folder}/.keep" 2>/dev/null || true
done

echo "Done. Bucket: gs://${BUCKET_NAME}"
echo "  Folders: raw/pml/, raw/ppl/, raw/tml/, raw/nppes/, raw/doge/, raw/roster_uploads/, cleansed/roster_uploads/"
echo "  Extract jobs: download from sources → upload to gs://${BUCKET_NAME}/raw/{source}/{YYYY-MM-DD}/"
echo "  Roster uploads: raw/roster_uploads/{upload_id}/, cleansed/roster_uploads/{upload_id}/"
