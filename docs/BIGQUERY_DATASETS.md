# BigQuery Dataset Organization (mobiusos-new)

Project: **mobiusos-new**

---

## Medicaid NPI: two datasets (canonical)

Use **one landing** and **one transformation** dataset for the Medicaid NPI pipeline. All dbt medicaid_npi models and scripts read/write only these.

| Role | Dataset | Env var | Contents |
|------|---------|--------|----------|
| **Landing / staging** | `landing_medicaid_npi_dev` | `BQ_LANDING_MEDICAID_DATASET` | Raw/staged: `stg_pml`, `stg_tml`, `stg_ppl`, `stg_doge`, `stg_nucc_taxonomy` (load from GCS/scripts). |
| **Transformation / marts** | `mobius_medicaid_npi_dev` | `BQ_MARTS_MEDICAID_DATASET` | dbt marts: `organizations`, `nppes_run`, `billing_servicing_pairs_run`, `step1a`…`step8`, `b6_integrated_report_fl`, etc. |

Set once (e.g. in `mobius-config/.env` or `mobius-dbt/.env`):

```bash
export BQ_LANDING_MEDICAID_DATASET=landing_medicaid_npi_dev
export BQ_MARTS_MEDICAID_DATASET=mobius_medicaid_npi_dev
```

**If the landing dataset is missing**, create both datasets (and optionally tables):

```bash
cd mobius-dbt
BQ_PROJECT=mobius-os-dev ./scripts/ensure_medicaid_datasets.sh
# Then create tables: python scripts/create_medicaid_infra.py
```

For other envs: `landing_medicaid_npi_staging` / `mobius_medicaid_npi_staging` (and prod) if you create them via `scripts/create_bq_datasets.sh`.

### Cleanup: remove duplicate or legacy datasets

If you see datasets like **`mobius_rag_landing_medicaid_npi_dev`** or **`mobius_rag_mobius_medicaid_npi_dev`**, they are **not** used by the codebase. Remove them with:

```bash
# From mobius-dbt; uses BQ_PROJECT (default mobiusos-new)
BQ_PROJECT=your-gcp-project ./scripts/remove_legacy_medicaid_datasets.sh
```

Keep only **`landing_medicaid_npi_dev`** and **`mobius_medicaid_npi_dev`** for Medicaid NPI.

---

## RAG: parallel env layout (dev / staging / prod)

| Dataset | Purpose |
|---------|--------|
| **landing_rag_dev** | RAG landing for dev. Table: `rag_published_embeddings`. Ingest writes here when `BQ_LANDING_DATASET=landing_rag_dev`. |
| **landing_rag_staging** | Landing for staging. Same table. |
| **landing_rag_prod** | Landing for prod. Same table. |
| **mobius_rag_dev** | Mart for dev. Tables: `published_rag_embeddings` (dbt), `sync_runs` (sync script). |
| **mobius_rag_staging** | Mart for staging. Same tables. |
| **mobius_rag_prod** | Mart for prod. Same tables. |

- **Landing** – ingest (RAG Postgres → BigQuery) writes to `landing_rag_{env}.rag_published_embeddings`.
- **Mart** – dbt reads landing and writes `mobius_rag_{env}.published_rag_embeddings`; sync reads mart and writes Chat + Vertex and optionally `mobius_rag_{env}.sync_runs`.

## Create datasets and tables

From the repo root (after `gcloud auth application-default login` or with `GOOGLE_APPLICATION_CREDENTIALS` set):

```bash
export BQ_PROJECT=mobiusos-new   # optional; default is mobiusos-new

# 1) Create all six datasets (landing_rag_dev/staging/prod, mobius_rag_dev/staging/prod)
./scripts/create_bq_datasets.sh

# 2) Create tables in each dataset (rag_published_embeddings in each landing_*, sync_runs in each mobius_rag_*)
./scripts/create_env_tables.sh
```

- **published_rag_embeddings** in each `mobius_rag_*` is created by `dbt run` when you set `BQ_DATASET=mobius_rag_{env}` (dbt creates the table on first run).

## Env vars per environment

| Env | BQ_LANDING_DATASET | BQ_DATASET |
|-----|--------------------|------------|
| Dev | `landing_rag_dev` | `mobius_rag_dev` |
| Staging | `landing_rag_staging` | `mobius_rag_staging` |
| Prod | `landing_rag_prod` | `mobius_rag_prod` |

Example for **dev** (ingest → dbt → sync):

```bash
export BQ_PROJECT=mobiusos-new
export BQ_LANDING_DATASET=landing_rag_dev
export BQ_DATASET=mobius_rag_dev
# then: ingest, dbt run, sync_mart_to_chat.py
```

dbt source reads from `BQ_LANDING_DATASET` (see `models/sources/_sources.yml`). Ingest and sync use the same vars (see `.env.example`).

## If `bq` hangs (stuck on `bq ls` or scripts)

1. **Test API reachability** (in another terminal):
   ```bash
   curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 https://bigquery.googleapis.com
   ```
   - `200` or `403` = reachable. Timeout = network/firewall/proxy blocking BigQuery.

2. **Enable BigQuery API** (if needed):  
   [APIs & Services → Enable BigQuery API](https://console.cloud.google.com/apis/library/bigquery.googleapis.com?project=mobiusos-new) for project **mobiusos-new**.

3. **Create datasets/tables in the Console** (no `bq` CLI needed):
   - Open [BigQuery → Explorer](https://console.cloud.google.com/bigquery?project=mobiusos-new).
   - Create the six datasets (Data location: US), then create the tables using the schemas in `scripts/create_landing_table.sql` and `scripts/create_sync_runs_table.sql` (substitute dataset name per env).
