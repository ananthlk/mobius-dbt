# BigQuery Dataset Organization (mobiusos-new)

Project: **mobiusos-new**

## Parallel env layout (dev / staging / prod)

| Dataset | Purpose |
|---------|--------|
| **landing_rag_dev** | Landing for dev. Table: `rag_published_embeddings`. Ingest writes here when `BQ_LANDING_DATASET=landing_rag_dev`. |
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
