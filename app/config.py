"""
Origin (dev/prod) and destination (dev/prod) env presets.
Reads from .env with prefixed vars (ORIGIN_DEV_*, ORIGIN_PROD_*, DEST_DEV_*, DEST_PROD_*)
and falls back to unprefixed vars for backward compatibility (dev = unprefixed).
"""
import os
from pathlib import Path
from typing import Dict, List, Literal, Optional

_PROJECT_ROOT = Path(__file__).resolve().parent.parent

try:
    from dotenv import load_dotenv
    load_dotenv(_PROJECT_ROOT / ".env")
except ImportError:
    pass

Origin = Literal["dev", "prod"]
Destination = Literal["dev", "prod"]

# Env keys used by ingest (RAG Postgres)
ORIGIN_KEYS = ["POSTGRES_HOST", "POSTGRES_PORT", "POSTGRES_DB", "POSTGRES_USER", "POSTGRES_PASSWORD"]
# Env keys used by dbt and sync (BQ, Chat, Vertex)
DEST_KEYS = [
    "BQ_PROJECT", "BQ_DATASET", "BQ_LANDING_DATASET", "BQ_TABLE", "BQ_SYNC_RUNS_TABLE",
    "CHAT_DATABASE_URL",
    "VERTEX_PROJECT", "VERTEX_REGION", "VERTEX_INDEX_ID", "VERTEX_INDEX_ENDPOINT_ID",
    "VERTEX_INDEX_MODE", "GCS_BUCKET", "GCS_PREFIX",
]


def _get_origin_env(origin: Origin) -> Dict[str, str]:
    """Build env dict for ingest step from selected origin (dev or prod). Prefixed ORIGIN_DEV_* / ORIGIN_PROD_* override; else fall back to unprefixed POSTGRES_* for both."""
    prefix = f"ORIGIN_{origin.upper()}_"
    out: Dict[str, str] = {}
    for key in ORIGIN_KEYS:
        val = os.environ.get(prefix + key) or os.environ.get(key)
        if val is not None:
            out[key] = str(val)
    return out


def _get_destination_env(destination: Destination) -> Dict[str, str]:
    """Build env dict for dbt/sync step from selected destination (dev or prod). Prefixed DEST_DEV_* / DEST_PROD_* override; else fall back to unprefixed vars for both."""
    prefix = f"DEST_{destination.upper()}_"
    out: Dict[str, str] = {}
    for key in DEST_KEYS:
        val = os.environ.get(prefix + key) or os.environ.get(key)
        if val is not None:
            out[key] = str(val)
    return out


def _load_env_file_into(base: Dict[str, str], path: Path, required_keys: Optional[list] = None) -> None:
    """Parse .env-style file and add KEY=VALUE into base. If required_keys given, set those when missing or empty."""
    if not path.exists():
        return
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                if line.startswith("export "):
                    line = line[7:].strip()
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                if not key:
                    continue
                if required_keys and key in required_keys:
                    if key not in base or not (base.get(key) or "").strip():
                        base[key] = value
                elif key not in base or not (base.get(key) or "").strip():
                    base[key] = value
    except Exception:
        pass


def get_env_for_run(origin: Origin, destination: Destination) -> Dict[str, str]:
    """
    Full env for a pipeline run: current process env + origin vars (for ingest) + destination vars (for dbt/sync).
    Caller should pass this to subprocess so ingest/dbt/sync see the chosen origin/destination.
    """
    # Ensure .env is loaded before copying (subprocess gets this env and won't inherit process env)
    try:
        from dotenv import load_dotenv
        load_dotenv(_PROJECT_ROOT / ".env")
    except ImportError:
        pass
    base = dict(os.environ)
    # Try mobius-dbt/.env, then parent (Mobius/.env), then mobius-config/.env
    env_candidates = [
        _PROJECT_ROOT / ".env",
        _PROJECT_ROOT.parent / ".env",
        _PROJECT_ROOT.parent / "mobius-config" / ".env",
    ]
    for env_file in env_candidates:
        _load_env_file_into(base, env_file, required_keys=ORIGIN_KEYS + DEST_KEYS)
    for env_file in env_candidates:
        _load_env_file_into(base, env_file)
    base.update(_get_origin_env(origin))
    base.update(_get_destination_env(destination))
    return base


def get_available_origins() -> list:
    """Return list of origin labels (dev, prod) that have at least POSTGRES_HOST set."""
    return ["dev", "prod"]


def get_available_destinations() -> list:
    """Return list of destination labels (dev, prod) that have at least BQ_DATASET or CHAT_DATABASE_URL set."""
    return ["dev", "prod"]
