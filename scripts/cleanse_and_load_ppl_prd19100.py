#!/usr/bin/env python3
"""
Back up current stg_ppl to stg_ppl_backup_YYYYMMDD, then cleanse prd19100.csv (FL Pending Provider List)
and load into stg_ppl.

Usage:
  python scripts/cleanse_and_load_ppl_prd19100.py --source /path/to/prd19100.csv --load

Env: BQ_PROJECT, BQ_LANDING_MEDICAID_DATASET, GCS_MEDICAID_BUCKET
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re
from datetime import date, datetime, timezone
from pathlib import Path

DEFAULT_SOURCE = "/Users/ananth/Downloads/cust 3/prod/dsfl/data/prd19100.csv"
PROGRAM_STATE = "FL"
PRODUCT = "medicaid"

# Emission prefix for progress (callers can filter stdout by this to show user-facing messages)
EMIT_PREFIX = "[EMIT] "

# prd19100 columns we map (source header -> normalized key). Others ignored.
COLUMN_ALIASES = {
    "NPI": "npi",
    "Pending Application Status": "status",
    "Pending Application Status Date": "submitted_date",
}


def _normalize_key(k: str) -> str:
    return (k or "").strip()


def _excel_unquote(v: str) -> str:
    s = (v or "").strip()
    if s.startswith("=") and len(s) > 2 and s[1] == '"' and s[-1] == '"':
        s = s[2:-1].strip()
    if s.startswith('"') and s.endswith('"'):
        s = s[1:-1].strip()
    return s


def _npi_digits(s: str) -> str:
    digits = re.sub(r"[^0-9]", "", (s or ""))
    return digits if len(digits) == 10 else ""


def _parse_date(s: str) -> str | None:
    if not s or not str(s).strip():
        return None
    s = str(s).strip()[:10]
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%Y/%m/%d", "%m-%d-%Y"):
        try:
            return datetime.strptime(s, fmt).strftime("%Y-%m-%d")
        except ValueError:
            continue
    return None


def _get(row: dict, *keys: str) -> str:
    for k in keys:
        if k in row:
            return str(row.get(k) or "")
        for rk in row:
            if _normalize_key(rk) == _normalize_key(k):
                return str(row.get(rk) or "")
    return ""


def backup_stg_ppl(project: str, dataset: str) -> dict:
    from google.cloud import bigquery
    client = bigquery.Client(project=project)
    table_id = f"{project}.{dataset}.stg_ppl"
    suffix = date.today().strftime("%Y%m%d")
    backup_id = f"{project}.{dataset}.stg_ppl_backup_{suffix}"
    try:
        client.get_table(table_id)
    except Exception as e:
        return {"status": "skipped", "reason": "table_not_found", "error": str(e)}
    query = f"CREATE OR REPLACE TABLE `{backup_id.replace('.', '`.`')}` AS SELECT * FROM `{table_id}`"
    try:
        client.query(query).result()
        t = client.get_table(backup_id)
        return {"status": "ok", "backup_table": backup_id, "backup_row_count": t.num_rows}
    except Exception as e:
        return {"status": "error", "error": str(e)}


def read_raw_rows(path: Path, encoding: str = "utf-8") -> tuple[list[dict], dict]:
    raw_stats = {"raw_row_count": 0, "raw_npi_count": 0}
    rows = []
    npis = set()
    for enc in (encoding, "utf-8-sig", "cp1252"):
        try:
            with open(path, "r", encoding=enc, newline="") as f:
                reader = csv.DictReader(f)
                for r in reader:
                    row = {_normalize_key(k): _excel_unquote(str(v)) for k, v in r.items()}
                    raw_stats["raw_row_count"] += 1
                    npi = _npi_digits(_get(row, "NPI"))
                    if npi:
                        npis.add(npi)
                    rows.append(row)
            raw_stats["raw_npi_count"] = len(npis)
            break
        except UnicodeDecodeError:
            continue
    return rows, raw_stats


def cleanse_rows(rows: list[dict]) -> tuple[list[dict], dict]:
    stats = {"cleansed_row_count": 0, "cleansed_npi_count": 0, "cleansed_dropped_no_npi": 0}
    out = []
    seen_npis = set()
    for r in rows:
        npi_raw = _get(r, "NPI")
        npi = _npi_digits(npi_raw)
        if not npi:
            stats["cleansed_dropped_no_npi"] += 1
            continue
        status = _get(r, "Pending Application Status").strip() or None
        submitted_raw = _get(r, "Pending Application Status Date").strip()
        submitted_date = _parse_date(submitted_raw) if submitted_raw else None
        # Dedupe by NPI (keep first row per NPI)
        if npi in seen_npis:
            continue
        seen_npis.add(npi)
        out.append({
            "program_state": PROGRAM_STATE,
            "product": PRODUCT,
            "npi": npi,
            "submitted_date": submitted_date or "",
            "status": status or "",
        })
    stats["cleansed_row_count"] = len(out)
    stats["cleansed_npi_count"] = len(seen_npis)
    return out, stats


def write_cleansed_csv(rows: list[dict], path: Path) -> None:
    fieldnames = ["program_state", "product", "npi", "submitted_date", "status"]
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def load_to_bigquery(cleansed_path: Path, project: str, dataset: str, bucket: str) -> dict:
    from google.cloud import bigquery, storage
    client = bigquery.Client(project=project)
    table_id = f"{project}.{dataset}.stg_ppl"
    date_suffix = date.today().strftime("%Y-%m-%d")
    gcs_path = f"raw/ppl/{date_suffix}/ppl_prd19100_cleansed.csv"
    uri = f"gs://{bucket}/{gcs_path}"
    storage.Client(project=project).bucket(bucket).blob(gcs_path).upload_from_filename(
        str(cleansed_path), content_type="text/csv"
    )
    schema = [
        bigquery.SchemaField("program_state", "STRING"),
        bigquery.SchemaField("product", "STRING"),
        bigquery.SchemaField("npi", "STRING"),
        bigquery.SchemaField("submitted_date", "DATE"),
        bigquery.SchemaField("status", "STRING"),
    ]
    job_config = bigquery.LoadJobConfig(
        schema=schema,
        skip_leading_rows=1,
        source_format=bigquery.SourceFormat.CSV,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        autodetect=False,
    )
    client.load_table_from_uri(uri, table_id, job_config=job_config).result()
    t = client.get_table(table_id)
    return {"loaded_row_count": t.num_rows, "gcs_uri": uri}


def main() -> int:
    parser = argparse.ArgumentParser(description="Cleanse prd19100 (PPL) and load into stg_ppl.")
    parser.add_argument("--source", type=Path, default=Path(DEFAULT_SOURCE), help="Path to prd19100.csv")
    parser.add_argument("--out-dir", type=Path, default=Path("mobius-dbt/data"))
    parser.add_argument("--stats", type=Path, default=Path("mobius-dbt/reports"))
    parser.add_argument("--load", action="store_true", help="Upload to GCS and load into BigQuery stg_ppl")
    parser.add_argument("--no-backup", action="store_true", help="Skip backup of current stg_ppl (e.g. first load)")
    args = parser.parse_args()

    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    dataset = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")
    bucket = os.environ.get("GCS_MEDICAID_BUCKET") or f"{project}-fl-medicaid-npi-raw"

    report = {
        "run_ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "source_file": str(args.source),
        "backup": None,
        "raw": None,
        "cleansed": None,
        "load": None,
    }

    if not args.no_backup:
        print(f"{EMIT_PREFIX}Backing up current stg_ppl...", flush=True)
        report["backup"] = backup_stg_ppl(project, dataset)
        if report["backup"].get("status") == "ok":
            print(f"  Backup: {report['backup']['backup_table']} ({report['backup']['backup_row_count']:,} rows)")
        else:
            print(f"  Backup: {report['backup'].get('status')} — {report['backup'].get('reason', report['backup'].get('error', ''))}")

    if not args.source.exists():
        print(f"Source not found: {args.source}")
        return 1

    print(f"{EMIT_PREFIX}Cleaning PPL (reading and normalizing)...", flush=True)
    rows, raw_stats = read_raw_rows(args.source)
    report["raw"] = raw_stats
    print(f"  Rows: {raw_stats['raw_row_count']:,} | Distinct NPIs: {raw_stats['raw_npi_count']:,}")

    cleansed, cleansed_stats = cleanse_rows(rows)
    report["cleansed"] = cleansed_stats
    print(f"  Cleansed rows: {cleansed_stats['cleansed_row_count']:,} | Distinct NPIs: {cleansed_stats['cleansed_npi_count']:,}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    args.stats.mkdir(parents=True, exist_ok=True)
    cleansed_path = args.out_dir / "ppl_prd19100_cleansed.csv"
    write_cleansed_csv(cleansed, cleansed_path)
    print(f"  Wrote {cleansed_path}")

    if args.load and cleansed:
        print(f"{EMIT_PREFIX}Uploading PPL to GCS and loading to BigQuery...", flush=True)
        report["load"] = load_to_bigquery(cleansed_path, project, dataset, bucket)
        print(f"{EMIT_PREFIX}PPL uploaded and loaded; ready for processing.", flush=True)
        print(f"  Loaded {report['load']['loaded_row_count']:,} rows into {project}.{dataset}.stg_ppl")

    with open(args.stats / "ppl_prd19100_control_stats.json", "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print(f"  Control stats: {args.stats / 'ppl_prd19100_control_stats.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
