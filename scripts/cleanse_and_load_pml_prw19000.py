#!/usr/bin/env python3
"""
Back up current stg_pml to stg_pml_backup_YYYYMMDD, then cleanse prw19000.csv and load into stg_pml.

Usage:
  python scripts/cleanse_and_load_pml_prw19000.py --source /path/to/prw19000.csv --load

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

DEFAULT_SOURCE = "/Users/ananth/Downloads/cust/prod/dsfl/data/prw19000.csv"
OPEN_END_DATE = "2299-12-31"
PROGRAM_STATE = "FL"
PRODUCT = "medicaid"

# Emission prefix for progress (callers can filter stdout by this to show user-facing messages)
EMIT_PREFIX = "[EMIT] "

# Full source column -> BQ-safe name (all columns for traceability). Source keys matched after strip().
SOURCE_COLUMNS = [
    ("Florida Medicaid Provider ID", "medicaid_provider_id"),
    ("Provider Name", "provider_name"),
    ("DBA Name", "dba_name"),
    ("Provider Type Code", "provider_type_code"),
    ("Provider Specialty Code", "provider_specialty_code"),
    ("Taxonomy Code", "taxonomy_code"),
    ("Service Location Address 1", "service_location_address_1"),
    ("Service Location Address 2", "service_location_address_2"),
    ("Service Location Address City", "service_location_address_city"),
    ("Service Location Address State", "service_location_address_state"),
    ("Service Location Address zip+4", "service_location_address_zip_plus_4"),
    ("Enrollment Type", "enrollment_type"),
    ("NPI Type 1 = Individual 2 = Organization U = Unknown", "npi_type"),
    ("NPI", "npi"),
    ("NPI Effective Date", "npi_effective_date"),
    ("NPI End Date", "npi_end_date"),
    ("NPI Status A = Active I = Inactive", "npi_status"),
    ("Individual or Organizational Provider", "individual_or_organizational_provider"),
    ("License", "license"),
    ("Current Medicaid Enrollment Status A = Active I = Inactive E = Ineligible", "current_medicaid_enrollment_status"),
    ("Medicaid Claims Eligibility Effective Date", "medicaid_claims_eligibility_effective_date"),
    ("Medicaid Claims Eligibility End Date", "medicaid_claims_eligibility_end_date"),
    ("Next Revalidation Date", "next_revalidation_date"),
]
SOURCE_BQ_NAMES = [bq for _src, bq in SOURCE_COLUMNS]


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


def _zip_split(s: str) -> tuple[str, str]:
    s = re.sub(r"[^0-9]", "", (s or ""))
    if len(s) >= 9:
        return s[:5], s[5:9]
    if len(s) >= 5:
        return s[:5], ""
    return s or "", ""


def _parse_date(s: str) -> str | None:
    if not s or not str(s).strip():
        return None
    s = str(s).strip()[:10]
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%Y/%m/%d"):
        try:
            return datetime.strptime(s, fmt).strftime("%Y-%m-%d")
        except ValueError:
            continue
    return None


def backup_stg_pml(project: str, dataset: str) -> dict:
    from google.cloud import bigquery
    client = bigquery.Client(project=project)
    table_id = f"{project}.{dataset}.stg_pml"
    suffix = date.today().strftime("%Y%m%d")
    backup_id = f"{project}.{dataset}.stg_pml_backup_{suffix}"
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
    raw_stats = {"raw_row_count": 0, "raw_enrollment_row_count": 0, "raw_location_only_row_count": 0, "raw_npi_count": 0, "raw_medicaid_id_count": 0}
    rows, npis, medicaid_ids = [], set(), set()
    for enc in (encoding, "utf-8-sig", "cp1252"):
        try:
            with open(path, "r", encoding=enc, newline="") as f:
                reader = csv.DictReader(f)
                for r in reader:
                    row = {_normalize_key(k): _excel_unquote(str(v)) for k, v in r.items()}
                    raw_stats["raw_row_count"] += 1
                    mid = (row.get("Florida Medicaid Provider ID") or "").strip()
                    if mid:
                        medicaid_ids.add(mid)
                    enroll = (row.get("Enrollment Type") or "").strip().upper()
                    npi_raw = (row.get("NPI") or "").strip()
                    npi = _npi_digits(npi_raw)
                    if enroll == "ENROLLMENT" and npi:
                        raw_stats["raw_enrollment_row_count"] += 1
                        npis.add(npi)
                    elif not npi_raw or not npi_raw.replace(" ", "").replace('"', ""):
                        raw_stats["raw_location_only_row_count"] += 1
                    rows.append(row)
            raw_stats["raw_npi_count"] = len(npis)
            raw_stats["raw_medicaid_id_count"] = len(medicaid_ids)
            break
        except UnicodeDecodeError:
            continue
    return rows, raw_stats


def _get(row: dict, *keys: str) -> str:
    for k in keys:
        if k in row:
            return str(row.get(k) or "")
        for rk in row:
            if rk.strip() == k.strip():
                return str(row.get(rk) or "")
    return ""


def _row_all_source_columns(r: dict) -> dict:
    """Map raw row to all source columns with BQ-safe names (for full traceability)."""
    out = {}
    for src_name, bq_name in SOURCE_COLUMNS:
        out[bq_name] = _get(r, src_name.strip()).strip()
    return out


def cleanse_rows(rows: list[dict]) -> tuple[list[dict], dict]:
    stats = {"cleansed_dropped_no_npi": 0, "cleansed_dropped_location_only": 0, "cleansed_dedup_dropped": 0,
             "cleansed_row_count": 0, "cleansed_npi_count": 0, "cleansed_npi_with_zip9_count": 0,
             "cleansed_status_active_count": 0, "cleansed_status_inactive_count": 0, "cleansed_status_ineligible_count": 0,
             "cleansed_contract_end_null_count": 0}
    out, seen = [], set()
    for r in rows:
        enroll = (r.get("Enrollment Type") or "").strip().upper()
        npi_raw = (r.get("NPI") or "").strip()
        npi = _npi_digits(npi_raw)
        if enroll != "ENROLLMENT":
            if not npi and not npi_raw.replace(" ", "").replace('"', ""):
                stats["cleansed_dropped_location_only"] += 1
            continue
        if not npi:
            stats["cleansed_dropped_no_npi"] += 1
            continue
        medicaid_id = (r.get("Florida Medicaid Provider ID") or "").strip()
        provider_name = (r.get("Provider Name") or "").strip()
        taxonomy_code = (r.get("Taxonomy Code") or "").strip()
        addr1 = _get(r, "Service Location Address 1").strip()
        city = _get(r, "Service Location Address City").strip()
        state = _get(r, "Service Location Address State").strip()
        zip_col = _get(r, "Service Location Address zip+4").strip()
        zip5, zip4 = _zip_split(zip_col)
        zip9 = (zip5 + zip4) if (len(zip5) == 5 and len(zip4) == 4) else (zip5 if len(zip5) == 5 else "")
        eff = _parse_date(r.get("NPI Effective Date") or "")
        end = _parse_date(r.get("NPI End Date") or "")
        if end and end == OPEN_END_DATE:
            end = None
        status_raw = _get(r, "Current Medicaid Enrollment Status A = Active I = Inactive E = Ineligible", "Current Medicaid Enrollment Status").strip().upper()
        status = status_raw[:1] if status_raw else "A"
        # Dedup key: (npi, taxonomy_code, zip9). Same key => keep first row only.
        # Source often has duplicate keys from: (1) Individual vs Organizational (I/O) rows for same NPI+taxonomy+address,
        # (2) identical rows. Downstream needs one row per credential per location (npi+taxonomy+zip9).
        key = (npi, taxonomy_code or "", zip9 or "")
        if key in seen:
            stats["cleansed_dedup_dropped"] += 1
            continue
        seen.add(key)
        # Full row: all source columns (traceability) + normalized pipeline columns
        row_out = _row_all_source_columns(r)
        row_out["npi"] = npi  # normalized 10-digit
        row_out["program_state"] = PROGRAM_STATE
        row_out["product"] = PRODUCT
        row_out["zip"] = zip5
        row_out["zip_plus_4"] = zip4
        row_out["contract_effective_date"] = eff or ""
        row_out["contract_end_date"] = end if end else "9999-12-31"
        row_out["status"] = status
        row_out["address_line_1"] = addr1  # pipeline alias
        row_out["city"] = city
        row_out["state"] = state
        out.append(row_out)
        if zip9:
            stats["cleansed_npi_with_zip9_count"] += 1
        if status == "A":
            stats["cleansed_status_active_count"] += 1
        elif status == "I":
            stats["cleansed_status_inactive_count"] += 1
        elif status == "E":
            stats["cleansed_status_ineligible_count"] += 1
        if not end:
            stats["cleansed_contract_end_null_count"] += 1
    stats["cleansed_row_count"] = len(out)
    stats["cleansed_npi_count"] = len(set(x["npi"] for x in out))
    stats["cleansed_npi_with_taxonomy_count"] = len(set((x["npi"], x["taxonomy_code"]) for x in out))
    return out, stats


def write_cleansed_csv(rows: list[dict], path: Path) -> None:
    # All source columns (BQ names) + pipeline columns for full traceability
    fieldnames = SOURCE_BQ_NAMES + [
        "program_state", "product", "zip", "zip_plus_4",
        "contract_effective_date", "contract_end_date", "status",
        "address_line_1", "city", "state",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def load_to_bigquery(cleansed_path: Path, project: str, dataset: str, bucket: str) -> dict:
    from google.cloud import bigquery, storage
    client = bigquery.Client(project=project)
    table_id = f"{project}.{dataset}.stg_pml"
    date_suffix = date.today().strftime("%Y-%m-%d")
    gcs_path = f"raw/pml/{date_suffix}/pml_prw19000_cleansed.csv"
    uri = f"gs://{bucket}/{gcs_path}"
    storage.Client(project=project).bucket(bucket).blob(gcs_path).upload_from_filename(str(cleansed_path), content_type="text/csv")
    # Full schema: all 23 source columns (STRING) + pipeline columns; contract dates as DATE for downstream
    schema = [bigquery.SchemaField(name, "STRING") for name in SOURCE_BQ_NAMES]
    schema += [
        bigquery.SchemaField("program_state", "STRING"),
        bigquery.SchemaField("product", "STRING"),
        bigquery.SchemaField("zip", "STRING"),
        bigquery.SchemaField("zip_plus_4", "STRING"),
        bigquery.SchemaField("contract_effective_date", "DATE"),
        bigquery.SchemaField("contract_end_date", "DATE"),
        bigquery.SchemaField("status", "STRING"),
        bigquery.SchemaField("address_line_1", "STRING"),
        bigquery.SchemaField("city", "STRING"),
        bigquery.SchemaField("state", "STRING"),
    ]
    job_config = bigquery.LoadJobConfig(schema=schema, skip_leading_rows=1, source_format=bigquery.SourceFormat.CSV,
                                        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE, autodetect=False)
    client.load_table_from_uri(uri, table_id, job_config=job_config).result()
    client.query(f"UPDATE `{table_id}` SET contract_end_date = NULL WHERE contract_end_date = DATE('9999-12-31')").result()
    t = client.get_table(table_id)
    return {"loaded_row_count": t.num_rows, "gcs_uri": uri}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path(DEFAULT_SOURCE))
    parser.add_argument("--out-dir", type=Path, default=Path("mobius-dbt/data"))
    parser.add_argument("--stats", type=Path, default=Path("mobius-dbt/reports"))
    parser.add_argument("--load", action="store_true")
    parser.add_argument("--no-backup", action="store_true", help="Skip backup (e.g. first load)")
    args = parser.parse_args()

    project = os.environ.get("BQ_PROJECT", "mobius-os-dev")
    dataset = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")
    bucket = os.environ.get("GCS_MEDICAID_BUCKET") or f"{project}-fl-medicaid-npi-raw"

    report = {"run_ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"), "source_file": str(args.source), "backup": None, "raw": None, "cleansed": None, "load": None}

    if not args.no_backup:
        print(f"{EMIT_PREFIX}Backing up current stg_pml...", flush=True)
        report["backup"] = backup_stg_pml(project, dataset)
        if report["backup"].get("status") == "ok":
            print(f"  Backup: {report['backup']['backup_table']} ({report['backup']['backup_row_count']:,} rows)")
        else:
            print(f"  Backup: {report['backup'].get('status')} — {report['backup'].get('reason', report['backup'].get('error', ''))}")

    if not args.source.exists():
        print(f"Source not found: {args.source}")
        return 1

    print(f"{EMIT_PREFIX}Cleaning PML (reading and normalizing)...", flush=True)
    rows, raw_stats = read_raw_rows(args.source)
    report["raw"] = raw_stats
    print(f"  Rows: {raw_stats['raw_row_count']:,} | Enrollment with NPI: {raw_stats['raw_enrollment_row_count']:,} | Location-only: {raw_stats['raw_location_only_row_count']:,} | Distinct NPIs: {raw_stats['raw_npi_count']:,}")

    cleansed, cleansed_stats = cleanse_rows(rows)
    report["cleansed"] = cleansed_stats
    print(f"  Cleansed rows: {cleansed_stats['cleansed_row_count']:,} | Distinct NPIs: {cleansed_stats['cleansed_npi_count']:,}")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    args.stats.mkdir(parents=True, exist_ok=True)
    cleansed_path = args.out_dir / "pml_prw19000_cleansed.csv"
    write_cleansed_csv(cleansed, cleansed_path)
    print(f"  Wrote {cleansed_path}")

    if args.load and cleansed:
        print(f"{EMIT_PREFIX}Uploading PML to GCS and loading to BigQuery...", flush=True)
        report["load"] = load_to_bigquery(cleansed_path, project, dataset, bucket)
        print(f"{EMIT_PREFIX}PML uploaded and loaded; ready for processing.", flush=True)
        print(f"  Loaded {report['load']['loaded_row_count']:,} rows into {project}.{dataset}.stg_pml")

    with open(args.stats / "pml_prw19000_control_stats.json", "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)
    print(f"  Control stats: {args.stats / 'pml_prw19000_control_stats.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
