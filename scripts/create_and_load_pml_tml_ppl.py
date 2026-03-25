#!/usr/bin/env python3
"""
Create and load stg_pml, stg_tml, stg_ppl in landing_medicaid_npi with unified schema.
Uses unified columns (program_state, product) per docs/MEDICAID_NPI_UNIFIED_LANDING.md.
Loads minimal placeholder rows so the pipeline can run; replace with real data later.

If these tables already exist with a different schema (e.g. from create_medicaid_infra.py),
drop them first in BigQuery or use a fresh dataset.

Usage:
  BQ_PROJECT=your-project BQ_LANDING_MEDICAID_DATASET=landing_medicaid_npi_dev python scripts/create_and_load_pml_tml_ppl.py
"""

import os
from google.cloud import bigquery

# Default project for Medicaid NPI landing (Mobius-OS-Dev)
PROJECT = os.environ.get("BQ_PROJECT", "mobius-os-dev")
LANDING = os.environ.get("BQ_LANDING_MEDICAID_DATASET", "landing_medicaid_npi_dev")
DEFAULT_STATE = "FL"
DEFAULT_PRODUCT = "medicaid"


def main():
    client = bigquery.Client(project=PROJECT)
    landing = f"{PROJECT}.{LANDING}"

    # --- stg_pml (Provider Master List) ---
    stg_pml = bigquery.Table(f"{landing}.stg_pml")
    stg_pml.schema = [
        bigquery.SchemaField("program_state", "STRING"),
        bigquery.SchemaField("product", "STRING"),
        bigquery.SchemaField("npi", "STRING"),
        bigquery.SchemaField("medicaid_provider_id", "STRING"),
        bigquery.SchemaField("provider_name", "STRING"),
        bigquery.SchemaField("provider_type", "STRING"),
        bigquery.SchemaField("specialty_type", "STRING"),
        bigquery.SchemaField("address_line_1", "STRING"),
        bigquery.SchemaField("city", "STRING"),
        bigquery.SchemaField("state", "STRING"),
        bigquery.SchemaField("zip", "STRING"),
        bigquery.SchemaField("zip_plus_4", "STRING"),
        bigquery.SchemaField("contract_effective_date", "DATE"),
        bigquery.SchemaField("contract_end_date", "DATE"),
        bigquery.SchemaField("status", "STRING"),
        bigquery.SchemaField("taxonomy_code", "STRING"),
    ]
    client.create_table(stg_pml, exists_ok=True)
    print(f"Created/verified {landing}.stg_pml")

    # Placeholder PML row (one enrolled provider so medicaid_provider_ids has something)
    pml_rows = [
        {
            "program_state": DEFAULT_STATE,
            "product": DEFAULT_PRODUCT,
            "npi": "0000000000",  # placeholder
            "medicaid_provider_id": None,
            "provider_name": "Placeholder Provider",
            "provider_type": None,
            "specialty_type": None,
            "address_line_1": None,
            "city": None,
            "state": DEFAULT_STATE,
            "zip": None,
            "zip_plus_4": None,
            "contract_effective_date": None,
            "contract_end_date": None,
            "status": "Active",
            "taxonomy_code": None,
        }
    ]
    errors = client.insert_rows_json(f"{landing}.stg_pml", pml_rows)
    if errors:
        # Table may already have rows; try truncate + insert or skip
        print(f"  Note: insert returned {errors} (table may already have data). Load real PML when ready.")
    else:
        print(f"  Loaded {len(pml_rows)} placeholder row(s) into stg_pml")

    # --- stg_tml (Taxonomy Master List) ---
    stg_tml = bigquery.Table(f"{landing}.stg_tml")
    stg_tml.schema = [
        bigquery.SchemaField("program_state", "STRING"),
        bigquery.SchemaField("product", "STRING"),
        bigquery.SchemaField("taxonomy_code", "STRING"),
        bigquery.SchemaField("taxonomy_description", "STRING"),
    ]
    client.create_table(stg_tml, exists_ok=True)
    print(f"Created/verified {landing}.stg_tml")

    # Common FL Medicaid-relevant taxonomy codes (seed so fl_medicaid_taxonomy has rows)
    tml_rows = [
        ("FL", "medicaid", "207R00000X", "Internal Medicine"),
        ("FL", "medicaid", "208D00000X", "General Practice"),
        ("FL", "medicaid", "207Q00000X", "Family Medicine"),
        ("FL", "medicaid", "163W00000X", "Registered Nurse"),
        ("FL", "medicaid", "363A00000X", "Physician Assistant"),
        ("FL", "medicaid", "261QM0801X", "Community Health and Mental Health"),
        ("FL", "medicaid", "1041C0700X", "Clinical Social Worker"),
        ("FL", "medicaid", "207RC0000X", "Cardiovascular Disease"),
        ("FL", "medicaid", "211D00000X", "Dentist"),
        ("FL", "medicaid", "282N00000X", "General Acute Care Hospital"),
    ]
    tml_insert = [
        {"program_state": s, "product": p, "taxonomy_code": c, "taxonomy_description": d}
        for s, p, c, d in tml_rows
    ]
    errors = client.insert_rows_json(f"{landing}.stg_tml", tml_insert)
    if errors:
        print(f"  Note: TML insert returned {errors} (table may already have data).")
    else:
        print(f"  Loaded {len(tml_insert)} row(s) into stg_tml")

    # --- stg_ppl (Pending Provider List) ---
    stg_ppl = bigquery.Table(f"{landing}.stg_ppl")
    stg_ppl.schema = [
        bigquery.SchemaField("program_state", "STRING"),
        bigquery.SchemaField("product", "STRING"),
        bigquery.SchemaField("npi", "STRING"),
        bigquery.SchemaField("submitted_date", "DATE"),
        bigquery.SchemaField("status", "STRING"),
    ]
    client.create_table(stg_ppl, exists_ok=True)
    print(f"Created/verified {landing}.stg_ppl")

    # No placeholder rows for PPL (empty is fine)
    print("  stg_ppl left empty (pipeline allows no pending providers).")

    print("")
    print("Done. Replace with real PML/TML/PPL data when available. Then: dbt run --select marts.medicaid_npi")


if __name__ == "__main__":
    main()
