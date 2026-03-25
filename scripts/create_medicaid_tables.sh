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
      program_state STRING,
      product STRING,
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
      taxonomy_code STRING,
      source_file STRING,
      ingested_at TIMESTAMP
    )
    OPTIONS(description = 'Landing: PML. Load via: uv run python scripts/load_medicaid_landing.py --pml /path/to/pml.csv');
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

  echo "  [$env] ${LANDING}.stg_ppl (Pending Provider List)..."
  bq query --project_id="$BQ_PROJECT" --use_legacy_sql=false --nouse_cache "
    CREATE TABLE IF NOT EXISTS \`${BQ_PROJECT}.${LANDING}.stg_ppl\` (
      program_state STRING,
      product STRING,
      npi STRING,
      submitted_date DATE,
      status STRING
    )
    OPTIONS(description = 'Landing: PPL (Pending Provider List). Load via: uv run python scripts/cleanse_and_load_ppl_prd19100.py --source /path/to/prd19100.csv --load');
  "

  echo "  [$env] ${LANDING}.stg_doge (DOGE Medicaid Provider Spending)..."
  bq query --project_id="$BQ_PROJECT" --use_legacy_sql=false --nouse_cache "
    CREATE TABLE IF NOT EXISTS \`${BQ_PROJECT}.${LANDING}.stg_doge\` (
      billing_npi STRING,
      servicing_npi STRING,
      hcpcs_code STRING,
      period_month STRING,
      beneficiary_count INT64,
      claim_count INT64,
      total_paid FLOAT64,
      state STRING
    )
    OPTIONS(description = 'Landing: DOGE Medicaid Provider Spending (HHS format). Load from GCS raw/doge/.');
  "

  echo "  [$env] ${LANDING}.stg_roster_upload (Roster upload for reconciliation)..."
  bq query --project_id="$BQ_PROJECT" --use_legacy_sql=false --nouse_cache "
    CREATE TABLE IF NOT EXISTS \`${BQ_PROJECT}.${LANDING}.stg_roster_upload\` (
      upload_id STRING,
      org_name STRING,
      row_num INT64,
      raw_npi STRING,
      raw_name STRING,
      npi_number STRING,
      provider_name STRING,
      raw_tin STRING,
      resolved_npi STRING,
      nppes_name STRING,
      nppes_status STRING,
      resolve_confidence STRING,
      uploaded_at TIMESTAMP
    )
    OPTIONS(description = 'Landing: Roster upload (cleansed). Load from GCS cleansed/roster_uploads/{upload_id}/roster_resolved.csv');
  "

  echo "  [$env] ${MART}.taxonomy_utilization_benchmarks (populate via scripts/populate_utilization_benchmarks.py)..."
  bq query --project_id="$BQ_PROJECT" --use_legacy_sql=false --nouse_cache "
    CREATE TABLE IF NOT EXISTS \`${BQ_PROJECT}.${MART}.taxonomy_utilization_benchmarks\` (
      taxonomy_code STRING,
      geography_type STRING,
      geography_value STRING,
      period STRING,
      claim_count INT64,
      total_revenue FLOAT64,
      member_count INT64,
      claims_per_member FLOAT64,
      revenue_per_member FLOAT64,
      revenue_per_claim FLOAT64
    )
    OPTIONS(description = 'Utilization benchmarks by taxonomy/geography. Populate: uv run python scripts/populate_utilization_benchmarks.py');
  "
done

echo "Done. NPPES: use bigquery-public-data.nppes (npi_optimized, npi_raw). Mart tables created by dbt run."
echo "  Run: BQ_PROJECT=$BQ_PROJECT BQ_LANDING_MEDICAID_DATASET=landing_medicaid_npi_dev BQ_MARTS_MEDICAID_DATASET=mobius_medicaid_npi_dev dbt run --select medicaid_npi"
