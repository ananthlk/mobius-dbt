#!/usr/bin/env python3
"""
Load all data into stg_pml, stg_tml, stg_ppl (unified schema with program_state, product).

PML: Required from FL AHCA. Download from portal or run scripts/download_ahca_medicaid.py --pml -o ./data.
     For daily loads with backup and cleanse, use scripts/cleanse_and_load_pml_prw19000.py --source ... --load.
TML: Optional. Seed from NPPES taxonomy if --tml not provided.
PPL: Optional. Load with --ppl /path/to/ppl.csv. CSV must have column 'npi'; optional 'submitted_date', 'status'.
     For FL prd19100 (Pending Provider List) format, use scripts/cleanse_and_load_ppl_prd19100.py first to
     cleanse and load (with backup); or pass a pre-cleaned CSV with columns npi, submitted_date, status.

Daily job: scripts/run_fl_medicaid_daily_load.sh runs download (optional), PML and PPL cleanse+load, then dbt.

Env: BQ_PROJECT (default mobius-os-dev), BQ_LANDING_MEDICAID_DATASET, PROGRAM_STATE (FL), PRODUCT (medicaid).

Usage:
  uv run python scripts/load_medicaid_landing.py --pml /path/to/pml.csv
  uv run python scripts/load_medicaid_landing.py --pml /path/to/pml.csv --ppl /path/to/ppl_cleansed.csv
"""

import argparse
import os
import csv
from pathlib import Path

PROJECT = os.environ.get("BQ_PROJECT", "mobius-os-dev")
LANDING = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")
PROGRAM_STATE = os.environ.get("PROGRAM_STATE", "FL")
PRODUCT = os.environ.get("PRODUCT", "medicaid")


def _landing():
    return f"`{PROJECT}.{LANDING}`"


def load_tml_from_nppes(client):
    """Seed stg_tml from NPPES taxonomy code set (BigQuery public)."""
    nppes_tml_table = None
    for table in [
        "bigquery-public-data.nppes.healthcare_provider_taxonomy_code_set_120",
        "bigquery-public-data.nppes.healthcare_provider_taxonomy_code_set",
    ]:
        try:
            client.query(f"SELECT 1 FROM `{table}` LIMIT 1").result()
            nppes_tml_table = table
            break
        except Exception:
            continue
    if not nppes_tml_table:
        print("  TML: No NPPES taxonomy table found. Use --tml /path/to/tml.csv to load from file.")
        return

    q = f"""
    TRUNCATE TABLE {_landing()}.stg_tml;
    INSERT INTO {_landing()}.stg_tml (program_state, product, taxonomy_code, taxonomy_description)
    SELECT
      '{PROGRAM_STATE}',
      '{PRODUCT}',
      TRIM(CAST(code AS STRING)),
      TRIM(COALESCE(CAST(`definition` AS STRING), ''))
    FROM `{nppes_tml_table}`
    WHERE code IS NOT NULL AND TRIM(CAST(code AS STRING)) != ''
    """
    job = client.query(q)
    job.result()
    t = client.get_table(f"{PROJECT}.{LANDING}.stg_tml")
    print(f"  Loaded {t.num_rows:,} rows into stg_tml (from NPPES)")


def load_tml_from_csv(client, path: str):
    """Load stg_tml from CSV. Expected columns: taxonomy_code, taxonomy_description (or code, definition)."""
    path = Path(path)
    if not path.exists():
        print(f"  TML CSV not found: {path}")
        return
    from google.cloud import bigquery

    rows = []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        r = csv.DictReader(f)
        for row in r:
            code = (row.get("taxonomy_code") or row.get("code") or "").strip()
            desc = (row.get("taxonomy_description") or row.get("definition") or "").strip()
            if not code:
                continue
            rows.append({"program_state": PROGRAM_STATE, "product": PRODUCT, "taxonomy_code": code, "taxonomy_description": desc})

    if not rows:
        print("  TML CSV had no valid rows.")
        return
    client.query(f"TRUNCATE TABLE {_landing()}.stg_tml;").result()
    errors = client.insert_rows_json(f"{PROJECT}.{LANDING}.stg_tml", rows)
    if errors:
        print(f"  TML insert errors: {errors[:3]}...")
    else:
        print(f"  Loaded {len(rows):,} rows into stg_tml (from CSV)")


def load_pml_from_csv(client, path: str):
    """Load stg_pml from CSV. Must have npi; add program_state, product. Other columns mapped by name."""
    path = Path(path)
    if not path.exists():
        print(f"  PML CSV not found: {path}")
        return
    from google.cloud import bigquery

    def get(row, *keys):
        for k in keys:
            if k in row and row[k] not in (None, ""):
                return str(row[k]).strip()
        return None

    rows = []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        r = csv.DictReader(f)
        for row in r:
            npi = get(row, "npi", "NPI")
            if not npi:
                continue
            rows.append({
                "program_state": PROGRAM_STATE,
                "product": PRODUCT,
                "npi": npi,
                "medicaid_provider_id": get(row, "medicaid_provider_id", "Medicaid Provider ID") or npi,
                "provider_name": get(row, "provider_name", "Provider Name", "provider_name_legal"),
                "provider_type": get(row, "provider_type", "Provider Type"),
                "specialty_type": get(row, "specialty_type", "Specialty", "taxonomy_code"),
                "address_line_1": get(row, "address_line_1", "Address", "service_location_address_1"),
                "city": get(row, "city", "City"),
                "state": get(row, "state", "State"),
                "zip": get(row, "zip", "ZIP", "service_location_address_zip"),
                "zip_plus_4": get(row, "zip_plus_4", "ZIP+4"),
                "contract_effective_date": get(row, "contract_effective_date"),
                "contract_end_date": get(row, "contract_end_date"),
                "status": get(row, "status", "Status") or "active",
                "taxonomy_code": get(row, "taxonomy_code", "Taxonomy Code"),
            })

    if not rows:
        print("  PML CSV had no valid rows (need npi column).")
        return
    client.query(f"TRUNCATE TABLE {_landing()}.stg_pml;").result()
    errors = client.insert_rows_json(f"{PROJECT}.{LANDING}.stg_pml", rows)
    if errors:
        print(f"  PML insert errors (first 3): {errors[:3]}")
    else:
        print(f"  Loaded {len(rows):,} rows into stg_pml (from CSV)")


def load_ppl_from_csv(client, path: str):
    """Load stg_ppl from CSV. Expected: npi; optional submitted_date, status. Adds program_state, product."""
    path = Path(path)
    if not path.exists():
        print(f"  PPL CSV not found: {path}")
        return
    rows = []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        r = csv.DictReader(f)
        for row in r:
            npi = (row.get("npi") or row.get("NPI") or "").strip()
            if not npi:
                continue
            rows.append({
                "program_state": PROGRAM_STATE,
                "product": PRODUCT,
                "npi": npi,
                "submitted_date": (row.get("submitted_date") or row.get("date") or "").strip() or None,
                "status": (row.get("status") or "").strip() or None,
            })
    if not rows:
        print("  PPL CSV had no valid rows.")
        return
    client.query(f"TRUNCATE TABLE {_landing()}.stg_ppl;").result()
    errors = client.insert_rows_json(f"{PROJECT}.{LANDING}.stg_ppl", rows)
    if errors:
        print(f"  PPL insert errors: {errors[:3]}")
    else:
        print(f"  Loaded {len(rows):,} rows into stg_ppl (from CSV)")


_PML_INSTRUCTIONS = """
PML is required from FL AHCA. NPPES seeding has been removed.

1. Download PML from Florida Medicaid Web Portal:
   https://portal.flmmis.com/FLPublic/Provider_ManagedCare/Provider_ManagedCare_Registration/
   Navigate to Provider Master List (PML). Export as CSV.

2. Or run the download helper:
   uv run python scripts/download_ahca_medicaid.py --pml -o ./pml.csv

3. Load into landing:
   uv run python scripts/load_medicaid_landing.py --pml /path/to/pml.csv
"""


def main():
    ap = argparse.ArgumentParser(description="Load stg_pml, stg_tml, stg_ppl (unified schema)")
    ap.add_argument("--pml", help="Path to PML CSV from FL AHCA")
    ap.add_argument("--use-existing-pml", action="store_true", help="Skip PML load; use existing stg_pml (for pipeline run when AHCA file not yet available)")
    ap.add_argument("--tml", help="Path to TML CSV (optional; else seed from NPPES taxonomy)")
    ap.add_argument("--ppl", help="Path to PPL CSV (optional; else leave empty)")
    args = ap.parse_args()

    from google.cloud import bigquery
    client = bigquery.Client(project=PROJECT)

    print(f"Project: {PROJECT}  Dataset: {LANDING}  program_state={PROGRAM_STATE}  product={PRODUCT}")
    print("")

    if args.tml:
        load_tml_from_csv(client, args.tml)
    else:
        print("TML: seeding from NPPES taxonomy...")
        load_tml_from_nppes(client)

    if args.use_existing_pml:
        print("PML: using existing stg_pml (--use-existing-pml). Replace with AHCA data when available.")
    elif args.pml:
        pml_path = Path(args.pml)
        if not pml_path.exists():
            print(f"  PML file not found: {args.pml}")
            print(_PML_INSTRUCTIONS)
            raise SystemExit(1)
        load_pml_from_csv(client, str(pml_path))
    else:
        print("PML: required. Provide --pml /path/to/pml.csv or --use-existing-pml to use current stg_pml.")
        print(_PML_INSTRUCTIONS)
        raise SystemExit(1)

    if args.ppl:
        load_ppl_from_csv(client, args.ppl)
    else:
        print("PPL: no file provided; leaving stg_ppl as-is (run with --ppl /path/to/ppl.csv to load).")
        print("  For FL prd19100 format: uv run python scripts/cleanse_and_load_ppl_prd19100.py --source /path/to/prd19100.csv --load")

    print("")
    print("Done. Run: dbt run --select marts.medicaid_npi")


if __name__ == "__main__":
    main()
