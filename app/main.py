"""
FastAPI app for Mobius DBT Job UI: trigger runs, list runs, run detail.
"""
import threading
from pathlib import Path
from typing import Literal, Optional

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from app import store
from app.runner import run_pipeline

app = FastAPI(title="Mobius DBT Job UI", version="1.0.0")

# Ensure DB exists on startup
@app.on_event("startup")
def startup():
    store.init_db()

# Static files (index.html, app.js) - mount after routes so /runs takes precedence
STATIC_DIR = Path(__file__).resolve().parent / "static"


class RunRequest(BaseModel):
    origin: Optional[Literal["dev", "prod"]] = "dev"
    destination: Optional[Literal["dev", "prod", "staging"]] = "dev"


@app.get("/config")
def get_config():
    """Return available origin and destination options (dev, prod)."""
    from app.config import get_available_origins, get_available_destinations
    return {"origins": get_available_origins(), "destinations": get_available_destinations()}


@app.post("/runs")
def start_run(body: Optional[RunRequest] = None):
    """Start the transformation (RAG → Chat) with selected origin and destination. Returns run_id; pipeline runs in background."""
    origin = (body.origin if body else None) or "dev"
    destination = (body.destination if body else None) or "dev"
    run_id = store.insert_run(origin=origin, destination=destination)
    thread = threading.Thread(target=run_pipeline, args=(run_id, origin, destination), daemon=True)
    thread.start()
    return {"run_id": run_id, "origin": origin, "destination": destination}


@app.get("/runs")
def list_runs(limit: int = 50):
    """List runs newest first."""
    runs = store.list_runs(limit=limit)
    return {"runs": runs}


@app.get("/runs/{run_id}")
def get_run(run_id: str):
    """Get run detail (status, stage, error_message, counts, started_at, finished_at)."""
    run = store.get_run(run_id)
    if run is None:
        raise HTTPException(status_code=404, detail="Run not found")
    return run


@app.get("/")
def index():
    """Serve the Job UI single page."""
    index_path = STATIC_DIR / "index.html"
    if not index_path.exists():
        raise HTTPException(status_code=404, detail="index.html not found")
    return FileResponse(index_path)


# Mount static assets (CSS, JS) under /static
if STATIC_DIR.exists():
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
