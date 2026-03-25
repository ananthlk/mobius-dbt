# FL Medicaid NPI — Phase 1 Setup

Phase 1 assembles GCS, BigQuery datasets, and dbt models for the Florida Medicaid NPI Initiative.

## Prerequisites

- `gcloud` and `bq` CLI with auth (`gcloud auth application-default login`)
- `gsutil` for GCS
- dbt (e.g. `uv run dbt` from mobius-dbt)

## 1. Create GCS Bucket

```bash
cd mobius-dbt
GCP_PROJECT=mobius-os-dev ./scripts/create_gcs_medicaid_bucket.sh
```

Creates `gs://mobius-os-dev-fl-medicaid-npi-raw/` with folders: `raw/pml/`, `raw/ppl/`, `raw/tml/`, `raw/nppes/`, `raw/doge/`.

## 2. Create BigQuery Datasets and Landing Tables

**Option A (Python, faster):**
```bash
BQ_PROJECT=mobius-os-dev uv run python scripts/create_medicaid_infra.py
```

**Option B (bq CLI):**
```bash
BQ_PROJECT=mobius-os-dev ./scripts/create_bq_datasets.sh
BQ_PROJECT=mobius-os-dev ./scripts/create_medicaid_tables.sh
```

Creates `landing_medicaid_npi_dev`, `mobius_medicaid_npi_dev` and tables `stg_pml`, `stg_tml`, `stg_doge`.

## 4. Run dbt (Medicaid Mart)

NPPES uses **BigQuery public data** `bigquery-public-data.nppes` (npi_optimized, npi_raw) — no load needed.

```bash
export BQ_PROJECT=mobius-os-dev
export BQ_LANDING_MEDICAID_DATASET=landing_medicaid_npi_dev
export BQ_MARTS_MEDICAID_DATASET=mobius_medicaid_npi_dev

# All Medicaid models (nppes_providers works immediately; others need landing populated)
uv run dbt run --select nppes_providers medicaid_provider_ids fl_medicaid_taxonomy billing_patterns

# Or use the pipeline script
./scripts/load_medicaid_and_dbt_run.sh
```

## 6. Sample org report (B6)

To produce a one-org report (e.g. for **Aspire Behavioral Health**) from the B6 integrated report:

```bash
# From mobius-dbt (after dbt run and landing data are in place)
uv run python scripts/sample_org_report_fl.py "Aspire Behavioral Health"
# Or save to file:
uv run python scripts/sample_org_report_fl.py "Aspire Behavioral Health" -o reports/aspire_behavioral_health_report.md
# By org_id (billing NPI):
uv run python scripts/sample_org_report_fl.py --org-id 1234567890 -o reports/org_1234567890.md
```

Requires `b6_integrated_report_fl` to exist (run `uv run dbt run --select +b6_integrated_report_fl` first). A mockup report is in `reports/aspire_behavioral_health_sample_report.md`.

- **nppes_providers**: View over `bigquery-public-data.nppes.npi_optimized` — works without landing.
- **medicaid_provider_ids**, **fl_medicaid_taxonomy**, **billing_patterns**: Require `landing_medicaid_npi_dev` dataset and tables (stg_pml, stg_tml, stg_doge).

## 5. Mart Tables

| Table | Source | Notes |
|-------|--------|------|
| `nppes_providers` | bigquery-public-data.nppes.npi_optimized | No load |
| `medicaid_provider_ids` | landing stg_pml | **PML from FL AHCA** (portal.flmmis.com). Use `load_medicaid_landing.py --pml /path/to/pml.csv`. NPPES seeding removed. |
| `fl_medicaid_taxonomy` | landing stg_tml | Load from GCS raw/tml/ |
| `billing_patterns` | landing stg_doge | Load from GCS raw/doge/; filter FL |
