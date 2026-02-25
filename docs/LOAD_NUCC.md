# NUCC Taxonomy Load

The `nucc_taxonomy` mart reads from `landing_medicaid_npi.stg_nucc_taxonomy`. Load that table before running dbt.

## Quick start (seed data)

```bash
cd mobius-dbt
python scripts/load_nucc_to_landing.py
```

Loads `seeds/nucc_taxonomy_seed.csv` (~50 codes) into BigQuery.

## Full NUCC (800+ codes)

1. Download NUCC CSV from https://www.nucc.org (Provider Taxonomy → CSV).
2. Ensure columns `taxonomy_code` and `taxonomy_description` (or map Code/Definition).
3. Run:

```bash
python scripts/load_nucc_to_landing.py /path/to/nucc_taxonomy_250.csv
```

## Environment

- `BQ_PROJECT` — GCP project (default: mobius-os-dev)
- `BQ_LANDING_MEDICAID_DATASET` — landing dataset (default: landing_medicaid_npi_dev)

## Schema

| Column | Type |
|--------|------|
| taxonomy_code | STRING |
| taxonomy_description | STRING |

## After load

```bash
dbt run --select nucc_taxonomy+
```
