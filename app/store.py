"""
SQLite job store: runs (and optional schedules) for the pipeline UI.
"""
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

# Default DB path: mobius-dbt/data/jobs.db
_PROJECT_ROOT = Path(__file__).resolve().parent.parent
_DEFAULT_DB_PATH = _PROJECT_ROOT / "data" / "jobs.db"


def _get_conn(db_path: Optional[Path] = None) -> sqlite3.Connection:
    path = db_path or _DEFAULT_DB_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    return conn


def init_db(db_path: Optional[Path] = None) -> None:
    """Create runs (and schedules) tables if they do not exist. Migrate runs table to add origin/destination if missing."""
    conn = _get_conn(db_path)
    try:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS runs (
                run_id TEXT PRIMARY KEY,
                started_at TEXT NOT NULL,
                finished_at TEXT,
                status TEXT NOT NULL,
                stage TEXT,
                error_message TEXT,
                mart_rows_read INTEGER,
                postgres_rows_written INTEGER,
                vector_rows_upserted INTEGER,
                origin TEXT,
                destination TEXT
            );
            CREATE TABLE IF NOT EXISTS schedules (
                schedule_id TEXT PRIMARY KEY,
                cron_expr TEXT,
                next_run_at TEXT,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at TEXT NOT NULL
            );
        """)
        conn.commit()
        # Migrate existing DBs: add origin/destination columns if missing
        cur = conn.execute("PRAGMA table_info(runs)")
        cols = {row[1] for row in cur.fetchall()}
        if "origin" not in cols:
            conn.execute("ALTER TABLE runs ADD COLUMN origin TEXT")
        if "destination" not in cols:
            conn.execute("ALTER TABLE runs ADD COLUMN destination TEXT")
        conn.commit()
    finally:
        conn.close()


def insert_run(
    origin: Optional[str] = None,
    destination: Optional[str] = None,
    db_path: Optional[Path] = None,
) -> str:
    """Insert a new run with status=running, stage=ingest. Returns run_id."""
    run_id = str(uuid.uuid4())
    conn = _get_conn(db_path)
    try:
        conn.execute(
            "INSERT INTO runs (run_id, started_at, finished_at, status, stage, origin, destination) VALUES (?, ?, NULL, ?, ?, ?, ?)",
            (run_id, datetime.now(timezone.utc).isoformat(), "running", "ingest", origin or "dev", destination or "dev"),
        )
        conn.commit()
        return run_id
    finally:
        conn.close()


def update_run(
    run_id: str,
    *,
    stage: Optional[str] = None,
    status: Optional[str] = None,
    finished_at: Optional[str] = None,
    error_message: Optional[str] = None,
    mart_rows_read: Optional[int] = None,
    postgres_rows_written: Optional[int] = None,
    vector_rows_upserted: Optional[int] = None,
    db_path: Optional[Path] = None,
) -> None:
    """Update run fields. Pass only the fields to update."""
    conn = _get_conn(db_path)
    try:
        updates: List[str] = []
        params: List[Any] = []
        if stage is not None:
            updates.append("stage = ?")
            params.append(stage)
        if status is not None:
            updates.append("status = ?")
            params.append(status)
        if finished_at is not None:
            updates.append("finished_at = ?")
            params.append(finished_at)
        if error_message is not None:
            updates.append("error_message = ?")
            params.append(error_message)
        if mart_rows_read is not None:
            updates.append("mart_rows_read = ?")
            params.append(mart_rows_read)
        if postgres_rows_written is not None:
            updates.append("postgres_rows_written = ?")
            params.append(postgres_rows_written)
        if vector_rows_upserted is not None:
            updates.append("vector_rows_upserted = ?")
            params.append(vector_rows_upserted)
        if not updates:
            return
        params.append(run_id)
        conn.execute(f"UPDATE runs SET {', '.join(updates)} WHERE run_id = ?", params)
        conn.commit()
    finally:
        conn.close()


def get_run(run_id: str, db_path: Optional[Path] = None) -> Optional[Dict[str, Any]]:
    """Get a single run by run_id."""
    conn = _get_conn(db_path)
    try:
        row = conn.execute("SELECT * FROM runs WHERE run_id = ?", (run_id,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def list_runs(limit: int = 50, db_path: Optional[Path] = None) -> List[Dict[str, Any]]:
    """List runs newest first."""
    conn = _get_conn(db_path)
    try:
        rows = conn.execute(
            "SELECT * FROM runs ORDER BY started_at DESC LIMIT ?", (limit,)
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()
