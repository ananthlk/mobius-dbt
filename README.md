# MOBIUS-DBT

dbt-managed BigQuery datalake for MOBIUS. Phase 1: consume RAG published embeddings, replicate in BigQuery landing, and expose a contracted mart for the chat server sync.

---

## Phase 1 scope

- **RAG source:** Mobius-RAG exposes one table in PostgreSQL: **`rag_published_embeddings`** (schema: Mobius RAG repo `docs/CONTRACT_DBT_RAG.md` Section 3). We have read access; we do not own RAG's database.
- **BigQuery landing:** Ingestion is **managed in this repo**. Script `scripts/ingest_rag_to_landing.py` copies `rag_published_embeddings` from RAG's PostgreSQL into BigQuery (dataset **`landing_rag`**, table **`rag_published_embeddings`**; `embedding` → ARRAY&lt;FLOAT64&gt;(1536)). Run **`./scripts/land_and_dbt_run.sh`** to ingest then build the mart (see [docs/LANDING_SCHEMA_AND_INGESTION.md](docs/LANDING_SCHEMA_AND_INGESTION.md)).
- **dbt:** This project sources from the BigQuery landing table and builds one mart: **`published_rag_embeddings`** in **`marts/chat_rag/`** (schema: `marts`, table: `published_rag_embeddings`). The mart has a dbt contract and tests (unique on `id`, not_null on key columns).
- **Sync:** After dbt run/test, the pipeline optionally syncs the mart to Mobius Chat: metadata → Chat Postgres (`published_rag_metadata`), embeddings → Vertex AI Vector Search. Script: `scripts/sync_mart_to_chat.py`. Contract: `docs/CONTRACT_MOBIUS_CHAT_PUBLISHED_RAG.md`.

---

## Contract and sign-off

- **Contract with RAG:** Mobius RAG repo `docs/CONTRACT_DBT_RAG.md` (Version 2026-02), Section 3.
- **Contract review and sign-off (this repo):** [docs/CONTRACT_REVIEW_AND_SIGNOFF.md](docs/CONTRACT_REVIEW_AND_SIGNOFF.md).
- **Landing schema and ingestion:** [docs/LANDING_SCHEMA_AND_INGESTION.md](docs/LANDING_SCHEMA_AND_INGESTION.md).

---

## Setup

1. **Python:** Use Python 3.9+.
2. **dbt:** Create a virtualenv and install dbt-bigquery:
   ```bash
   ./scripts/install_dbt.sh
   source .venv/bin/activate   # Windows: .venv\Scripts\activate
   dbt --version
   ```
   Or manually: `python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt`  
   If you hit SSL errors with pip, try: `pip install --trusted-host pypi.org --trusted-host files.pythonhosted.org -r requirements.txt`  
   If you see **"bad interpreter: ... no such file or directory"** (e.g. after moving the repo or path/case change), the venv points at an old path. Remove and recreate: `rm -rf .venv && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt`
3. **BigQuery:** Set `BQ_PROJECT` (GCP project) and optionally `BQ_DATASET` (default dataset for dbt models). For sources, the landing table must exist in dataset **`landing_rag`** (or override in `models/sources/_sources.yml`). Authenticate via `gcloud auth application-default login` or `GOOGLE_APPLICATION_CREDENTIALS`.
4. **Landing table:** Create it once (BigQuery Console: run **`scripts/create_landing_table.sql`**). Then run **`./scripts/land_and_dbt_run.sh`** (set `POSTGRES_HOST`, `POSTGRES_PASSWORD`) to ingest from RAG Postgres and run dbt. See [docs/LANDING_SCHEMA_AND_INGESTION.md](docs/LANDING_SCHEMA_AND_INGESTION.md) for env vars and scheduling.

---

## Commands

- **Full pipeline (ingest + dbt run + dbt test + sync):**  
  `export POSTGRES_HOST=... POSTGRES_PASSWORD=... CHAT_DATABASE_URL=... VERTEX_INDEX_ID=... && ./scripts/land_and_dbt_run.sh`  
  Sync step (mart → Chat) runs if `CHAT_DATABASE_URL` and Vertex env vars are set; skipped otherwise.
- **Ingest only (RAG Postgres → BigQuery landing):**  
  `python scripts/ingest_rag_to_landing.py` (requires `POSTGRES_HOST`, `POSTGRES_PASSWORD`)
- **Sync only (mart → Chat Postgres + Vertex):**  
  `python scripts/sync_mart_to_chat.py` (requires `BQ_PROJECT`, `BQ_DATASET`, `CHAT_DATABASE_URL`, `VERTEX_PROJECT`, `VERTEX_REGION`, `VERTEX_INDEX_ID`)
- **Install dbt deps (if using packages):** `dbt deps`
- **Run models:** `dbt run`
- **Run tests:** `dbt test`
- **Build (run + test):** `dbt build`
- **Generate docs:** `dbt docs generate`
- **Serve docs:** `dbt docs serve`

---

## Job UI

A simple web interface to trigger the transformation (RAG → Chat), view run status, and follow progress.

1. **Activate the virtualenv** (required so `pip` and `uvicorn` are available):
   ```bash
   source .venv/bin/activate   # macOS/Linux
   # Windows: .venv\Scripts\activate
   ```
   If you don't have a venv yet: `python3 -m venv .venv` then activate, then `pip install -r requirements.txt`.
2. **Run the server** (from repo root, with `.env` set for origin/destination):
   ```bash
   pip install -r requirements.txt   # if you haven't already
   uvicorn app.main:app --reload --host 0.0.0.0 --port 6500
   ```
   Or without activating venv: `./.venv/bin/python -m uvicorn app.main:app --reload --port 6500`
3. **Open the page:** http://localhost:6500/
4. **Run now:** Click "Run now" to start the pipeline (ingest → dbt run → dbt test → sync). The run appears in the table with status and stage.
5. **Status:** The runs table lists recent runs (started, status, stage, finished, error). It auto-refreshes every 5s while a run is in progress. Use "View" to see full run detail (counts, error message).
6. **Origin and destination:** Use the dropdowns to choose **Origin** (Dev / Prod) and **Destination** (Dev / Prod). Dev uses unprefixed vars from `.env` (e.g. `POSTGRES_HOST`, `BQ_DATASET`, `CHAT_DATABASE_URL`). For prod, set prefixed vars: `ORIGIN_PROD_POSTGRES_HOST`, `ORIGIN_PROD_POSTGRES_PASSWORD`, etc., and `DEST_PROD_BQ_DATASET`, `DEST_PROD_CHAT_DATABASE_URL`, `DEST_PROD_VERTEX_INDEX_ID`, etc. See `.env.example` for the full list.

Run metadata is stored in `data/jobs.db` (SQLite; `data/` is gitignored).

---

## CI

Recommended CI steps:

1. `dbt debug` (optional: verify connection).
2. `dbt run` – build models.
3. `dbt test` – run tests (unique, not_null on `published_rag_embeddings`).
4. Optionally: `dbt docs generate` and publish artifact.

Or use a single command: **`dbt build`** (runs models and tests).

---

## Project layout (Phase 1)

```
MOBIUS-DBT/
├── app/                         # Job UI (FastAPI + runner + static)
│   ├── main.py                  # API: POST/GET /runs, GET /runs/{id}
│   ├── runner.py                # Pipeline: ingest → dbt → sync
│   ├── store.py                 # SQLite runs store
│   └── static/
│       ├── index.html           # Single-page UI
│       ├── app.js
│       └── style.css
├── data/                        # SQLite jobs.db (gitignored)
├── dbt_project.yml
├── profiles.yml
├── README.md
├── docs/
│   ├── CONTRACT_REVIEW_AND_SIGNOFF.md
│   └── LANDING_SCHEMA_AND_INGESTION.md
├── models/
│   ├── sources/
│   │   └── _sources.yml          # source: landing_rag.rag_published_embeddings
│   └── marts/
│       └── chat_rag/
│           ├── published_rag_embeddings.sql
│           └── schema.yml        # contract + tests
├── macros/
├── analyses/
└── tests/
```

---

## Vision (later phases)

Full datalake: staging, core, and marts for analytics, ML, patient_attributes, agents, user_frontend. See the architecture plan for the full structure.
