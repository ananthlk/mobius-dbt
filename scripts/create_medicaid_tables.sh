#!/usr/bin/env bash
# Create FL Medicaid NPI landing and mart tables.
# Run after create_bq_datasets.sh. Requires: bq CLI and auth.
#
# Landing tables: populated by load jobs from GCS (PML, PPL, TML, DOGE).
# NPPES: use bigquery-public-data.nppes (npi_optimized, npi_raw) directly via dbt view.
#
# Usage: BQ_PROJECT=mobius-os-dev ./scripts/create_medicaid_tables.sh

set -e
BQ_PROJECT="${BQ_PROJECT:-mobius-os-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Creating FL Medicaid NPI tables in project: $BQ_PROJECT"

for env in dev staging prod; do
  LANDING="landing_medicaid_npi_${env}"
  MART="mobius_medicaid_npi_${env}"

  echo "  [$env] ${LANDING}.stg_pml (Provider Master List)..."
  bq query --project_id="$BQ_PROJECT" --use_legacy_sql=false --nouse_cache "
    CREATE TABLE IF NOT EXISTS \`${BQ_PROJECT}.${LANDING}.stg_pml\` (
      medicaid_provider_id STRING,
      npi STRING,
      provider_name STRING,
      provider_type STRING,
      specialty_type STRING,
      address_line_1 STRING,
      city STRING,
      state STRING,
      zip STRING,
      zip_plus_4 STRING,
      contract_effective_date DATE,
      contract_end_date DATE,
      status STRING,
      source_file STRING,
      ingested_at TIMESTAMP
    )
    OPTIONS(description = 'Landing: PML (Provider Master List). Load from GCS raw/pml/. Schema aligns with FL Medicaid PML layout.');
  "

  echo "  [$env] ${LANDING}.stg_tml (Taxonomy Master List)..."
  bq query --project_id="$BQ_PROJECT" --use_legacy_sql=false --nouse_cache "
    CREATE TABLE IF NOT EXISTS \`${BQ_PROJECT}.${LANDING}.stg_tml\` (
      taxonomy_code STRING,
      taxonomy_description STRING,
      provider_type STRING,
      provider_type_number INT64,
      specialty_type STRING,
      specialty_type_number INT64,
      source_file STRING,
      ingested_at TIMESTAMP
    )
    OPTIONS(description = 'Landing: TML (Taxonomy Master List). Load from GCS raw/tml/.');
  "

  echo "  [$env] ${LANDING}.stg_doge (DOGE Medicaid Provider Spending)..."
  bq query --project_id="$BQ_PROJECT" --use_legacy_sql=false --nouse_cache "
    CREATE TABLE IF NOT EXISTS \`${BQ_PROJECT}.${LANDING}.stg_doge\` (
      npi STRING,
      billing_tin STRING,
      servicing_tin STRING,
      hcpcs_code STRING,
      period_month STRING,
      beneficiary_count INT64,
      claim_count INT64,
      total_paid FLOAT64,
      state STRING
    )
    OPTIONS(description = 'Landing: DOGE Medicaid Provider Spending. Load from GCS raw/doge/. Filter FL in dbt.');
  "
done

echo "Done. NPPES: use bigquery-public-data.nppes (npi_optimized, npi_raw). Mart tables created by dbt run."
echo "  Run: BQ_PROJECT=$BQ_PROJECT BQ_LANDING_MEDICAID_DATASET=landing_medicaid_npi_dev BQ_MARTS_MEDICAID_DATASET=mobius_medicaid_npi_dev dbt run --select medicaid_npi"
