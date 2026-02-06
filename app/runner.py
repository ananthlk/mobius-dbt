"""
Pipeline runner: ingest → dbt run + test → sync. Runs in background; updates SQLite store.
Supports origin (dev/prod) and destination (dev/prod/staging); runs each step in subprocess with env from config.
Uses dbt's programmatic API (dbtRunner) so dbt runs without needing the 'dbt' CLI binary (works in Docker/Cloud Run).
"""
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal, Optional

# Project root (mobius-dbt)
PROJECT_ROOT = Path(__file__).resolve().parent.parent

try:
    from dotenv import load_dotenv
    load_dotenv(PROJECT_ROOT / ".env")
except ImportError:
    pass

Origin = Literal["dev", "prod"]
Destination = Literal["dev", "prod", "staging"]


def run_pipeline(run_id: str, origin: Origin = "dev", destination: Destination = "dev") -> None:
    """
    Run the full pipeline (ingest → dbt → sync) with the given origin and destination.
    Uses env from app.config.get_env_for_run(origin, destination) for all steps.
    Called from a background thread; run_id was already inserted by the API.
    """
    # Load .env so get_env_for_run sees POSTGRES_*, BQ_*, etc. (subprocess gets env dict, not process env)
    try:
        from dotenv import load_dotenv
        load_dotenv(PROJECT_ROOT / ".env")
    except ImportError:
        pass
    from app import store
    from app.config import get_env_for_run

    env = get_env_for_run(origin, destination)
    store.update_run(run_id, stage="ingest")

    try:
        # 1. Ingest RAG PostgreSQL → BigQuery landing (subprocess so env is applied)
        ingest_script = PROJECT_ROOT / "scripts" / "ingest_rag_to_landing.py"
        result = subprocess.run(
            [sys.executable, str(ingest_script)],
            cwd=PROJECT_ROOT,
            env=env,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            store.update_run(
                run_id,
                status="failure",
                finished_at=datetime.now(timezone.utc).isoformat(),
                error_message="ingest_rag_to_landing failed: " + (result.stderr or result.stdout or "no output"),
            )
            return

        # 2. dbt run + dbt test (use dbtRunner so no 'dbt' CLI binary needed; works in Docker/Cloud Run)
        store.update_run(run_id, stage="dbt")
        try:
            from dbt.cli.main import dbtRunner
        except ImportError:
            store.update_run(
                run_id,
                status="failure",
                finished_at=datetime.now(timezone.utc).isoformat(),
                error_message="dbt not installed (pip install dbt-bigquery)",
            )
            return
        # dbt reads BQ_PROJECT, BQ_DATASET, BQ_LANDING_DATASET from env (profiles.yml)
        prev_env = dict(os.environ)
        try:
            os.environ.clear()
            os.environ.update(prev_env)
            os.environ.update(env)
            project_dir = str(PROJECT_ROOT)
            dbt = dbtRunner()
            for dbt_cmd in ["run", "test"]:
                res = dbt.invoke([dbt_cmd, "--project-dir", project_dir])
                if not res.success:
                    msg = (res.exception and str(res.exception)) or (getattr(res, "result", None) and str(res.result)) or f"dbt {dbt_cmd} failed"
                    # Cap length for DB/store
                    if len(msg) > 2000:
                        msg = msg[:1997] + "..."
                    store.update_run(
                        run_id,
                        status="failure",
                        finished_at=datetime.now(timezone.utc).isoformat(),
                        error_message=msg,
                    )
                    return
        finally:
            os.environ.clear()
            os.environ.update(prev_env)

        # 3. Sync mart → Chat (Postgres + Vertex)
        # For staging: use --dest staging --postgres-only (Vertex index is shared)
        store.update_run(run_id, stage="sync")
        sync_script = PROJECT_ROOT / "scripts" / "sync_mart_to_chat.py"
        sync_cmd = [sys.executable, str(sync_script)]
        if destination == "staging":
            sync_cmd.extend(["--dest", "staging", "--postgres-only"])
        result = subprocess.run(
            sync_cmd,
            cwd=PROJECT_ROOT,
            env=env,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            store.update_run(
                run_id,
                status="failure",
                finished_at=datetime.now(timezone.utc).isoformat(),
                error_message="sync_mart_to_chat failed: " + (result.stderr or result.stdout or "no output"),
            )
            return

        # Success: set status and optionally fetch sync counts from BigQuery
        finished_at = datetime.now(timezone.utc).isoformat()
        mart_rows = postgres_rows = vector_rows = None
        bq_project = env.get("BQ_PROJECT")
        bq_dataset = env.get("BQ_DATASET")
        if bq_project and bq_dataset:
            try:
                from google.cloud import bigquery
                client = bigquery.Client(project=bq_project)
                sync_runs_table = env.get("BQ_SYNC_RUNS_TABLE", f"{bq_dataset}.sync_runs")
                table_id = f"{bq_project}.{sync_runs_table}"
                query = f"""
                    SELECT mart_rows_read, postgres_rows_written, vector_rows_upserted
                    FROM `{table_id}`
                    ORDER BY started_at DESC
                    LIMIT 1
                """
                for row in client.query(query).result():
                    mart_rows = row.mart_rows_read
                    postgres_rows = row.postgres_rows_written
                    vector_rows = row.vector_rows_upserted
                    break
            except Exception:
                pass  # leave counts null

        store.update_run(
            run_id,
            status="success",
            finished_at=finished_at,
            stage="sync",
            mart_rows_read=mart_rows,
            postgres_rows_written=postgres_rows,
            vector_rows_upserted=vector_rows,
        )
    except Exception as e:
        from app import store
        store.update_run(
            run_id,
            status="failure",
            finished_at=datetime.now(timezone.utc).isoformat(),
            error_message=str(e),
        )
