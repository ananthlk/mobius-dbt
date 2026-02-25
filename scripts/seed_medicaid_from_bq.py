#!/usr/bin/env python3
"""
Seed TML and PML from BigQuery (NPPES public data). Upload to GCS, load to landing.
Use when DOGE/HuggingFace is slow or unavailable. PML seeds FL providers from npi_optimized.
"""
import os
from datetime import datetime
from google.cloud import bigquery, storage

PROJECT = os.environ.get("BQ_PROJECT", "mobius-os-dev")
BUCKET = os.environ.get("GCS_MEDICAID_BUCKET", f"{PROJECT}-fl-medicaid-npi-raw")


def seed_tml():
    """Export NPPES taxonomy to GCS, load to stg_tml."""
    client = bigquery.Client(project=PROJECT)
    today = datetime.now().strftime("%Y-%m-%d")
    dest_uri = f"gs://{BUCKET}/raw/tml/{today}/tml_seed.csv"

    query = """
    SELECT
      code AS taxonomy_code,
      COALESCE(`definition`, CONCAT(IFNULL(`grouping`,''), ' - ', IFNULL(classification,''))) AS taxonomy_description,
      `grouping` AS provider_type,
      CAST(NULL AS INT64) AS provider_type_number,
      specialization AS specialty_type,
      CAST(NULL AS INT64) AS specialty_type_number
    FROM `bigquery-public-data.nppes.healthcare_provider_taxonomy_code_set_120`
    """
    job_config = bigquery.QueryJobConfig(destination=f"{PROJECT}.landing_medicaid_npi_dev.stg_tml")
    # Export to GCS then load
    extract_config = bigquery.ExtractJobConfig(destination_format="CSV", print_header=True)
    query_job = client.query(query)
    rows = list(query_job.result())
    if not rows:
        print("No TML rows")
        return

    import csv
    import tempfile
    from pathlib import Path
    p = Path(tempfile.mkdtemp()) / "tml.csv"
    with open(p, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(
            f,
            fieldnames=["taxonomy_code", "taxonomy_description", "provider_type", "provider_type_number", "specialty_type", "specialty_type_number"],
        )
        w.writeheader()
        for r in rows:
            w.writerow({
                "taxonomy_code": r.taxonomy_code or "",
                "taxonomy_description": r.taxonomy_description or "",
                "provider_type": r.provider_type or "",
                "provider_type_number": r.provider_type_number or "",
                "specialty_type": r.specialty_type or "",
                "specialty_type_number": r.specialty_type_number or "",
            })

    storage.Client(project=PROJECT).bucket(BUCKET).blob(f"raw/tml/{today}/tml_seed.csv").upload_from_filename(str(p), content_type="text/csv")
    print(f"Uploaded TML to gs://{BUCKET}/raw/tml/{today}/tml_seed.csv")

    table_id = f"{PROJECT}.landing_medicaid_npi_dev.stg_tml"
    config = bigquery.LoadJobConfig(
        schema=[
            bigquery.SchemaField("taxonomy_code", "STRING"),
            bigquery.SchemaField("taxonomy_description", "STRING"),
            bigquery.SchemaField("provider_type", "STRING"),
            bigquery.SchemaField("provider_type_number", "INT64"),
            bigquery.SchemaField("specialty_type", "STRING"),
            bigquery.SchemaField("specialty_type_number", "INT64"),
        ],
        skip_leading_rows=1,
        source_format=bigquery.SourceFormat.CSV,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    client.load_table_from_uri(f"gs://{BUCKET}/raw/tml/{today}/tml_seed.csv", table_id, job_config=config).result()
    t = client.get_table(table_id)
    print(f"Loaded {t.num_rows} rows into stg_tml")


def seed_pml():
    """Seed PML from NPPES FL providers (npi as medicaid_provider_id placeholder)."""
    client = bigquery.Client(project=PROJECT)
    # npi_optimized - get schema and sample FL providers
    query = """
    SELECT
      npi AS medicaid_provider_id,
      npi,
      COALESCE(provider_organization_name_legal_business_name, CONCAT(provider_last_name_legal_name, ', ', provider_first_name)) AS provider_name,
      entity_type_code AS provider_type,
      healthcare_provider_taxonomy_code_1 AS specialty_type,
      provider_first_line_business_practice_location_address AS address_line_1,
      provider_business_practice_location_address_city_name AS city,
      provider_business_practice_location_address_state_name AS state,
      provider_business_practice_location_address_postal_code AS zip,
      CAST(NULL AS STRING) AS zip_plus_4,
      CAST(NULL AS DATE) AS contract_effective_date,
      CAST(NULL AS DATE) AS contract_end_date,
      'active' AS status
    FROM `bigquery-public-data.nppes.npi_optimized`
    WHERE provider_business_practice_location_address_state_name = 'FL'
    """
    try:
        rows = list(client.query(query).result())
    except Exception as e:
        print(f"PML seed query failed (npi_optimized schema may differ): {e}")
        return
    if not rows:
        print("No PML rows")
        return

    import csv
    import tempfile
    from pathlib import Path
    p = Path(tempfile.mkdtemp()) / "pml.csv"
    fieldnames = ["medicaid_provider_id", "npi", "provider_name", "provider_type", "specialty_type", "address_line_1", "city", "state", "zip", "zip_plus_4", "contract_effective_date", "contract_end_date", "status"]
    with open(p, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: (getattr(r, k, None) or "") for k in fieldnames})

    today = datetime.now().strftime("%Y-%m-%d")
    storage.Client(project=PROJECT).bucket(BUCKET).blob(f"raw/pml/{today}/pml_seed.csv").upload_from_filename(str(p), content_type="text/csv")
    print(f"Uploaded PML to gs://{BUCKET}/raw/pml/{today}/pml_seed.csv")

    table_id = f"{PROJECT}.landing_medicaid_npi_dev.stg_pml"
    config = bigquery.LoadJobConfig(
        schema=[bigquery.SchemaField(f, "STRING") for f in fieldnames[:10]]
        + [bigquery.SchemaField("zip_plus_4", "STRING"), bigquery.SchemaField("contract_effective_date", "DATE"), bigquery.SchemaField("contract_end_date", "DATE")]
        + [bigquery.SchemaField("status", "STRING")],
        skip_leading_rows=1,
        source_format=bigquery.SourceFormat.CSV,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
    )
    # Simpler schema - all string
    config.schema = [
        bigquery.SchemaField("medicaid_provider_id", "STRING"),
        bigquery.SchemaField("npi", "STRING"),
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
    ]
    client.load_table_from_uri(f"gs://{BUCKET}/raw/pml/{today}/pml_seed.csv", table_id, job_config=config).result()
    t = client.get_table(table_id)
    print(f"Loaded {t.num_rows} rows into stg_pml")


def main():
    print("=== TML seed from NPPES ===")
    seed_tml()
    print("\n=== PML seed from NPPES (FL providers) ===")
    seed_pml()
    print("\n=== DOGE ===")
    print("Run: uv run python scripts/extract_and_load_medicaid.py (requires Hugging Face datasets)")


if __name__ == "__main__":
    main()
