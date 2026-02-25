#!/usr/bin/env python3
"""Create FL Medicaid NPI BigQuery datasets and tables. Uses google-cloud-bigquery."""
import os
from google.cloud import bigquery

PROJECT = os.environ.get("BQ_PROJECT", "mobius-os-dev")
LOCATION = os.environ.get("BQ_LOCATION", "US")

def main():
    client = bigquery.Client(project=PROJECT, location=LOCATION)

    # Create datasets
    for name in ["landing_medicaid_npi_dev", "mobius_medicaid_npi_dev"]:
        ds = bigquery.Dataset(f"{PROJECT}.{name}")
        ds.location = LOCATION
        try:
            client.create_dataset(ds, exists_ok=True)
            print(f"Created dataset: {name}")
        except Exception as e:
            print(f"Dataset {name}: {e}")

    # Create landing tables in landing_medicaid_npi_dev
    landing = f"{PROJECT}.landing_medicaid_npi_dev"

    stg_pml = bigquery.Table(f"{landing}.stg_pml")
    stg_pml.schema = [
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
        bigquery.SchemaField("source_file", "STRING"),
        bigquery.SchemaField("ingested_at", "TIMESTAMP"),
    ]
    client.create_table(stg_pml, exists_ok=True)
    print("Created landing_medicaid_npi_dev.stg_pml")

    stg_tml = bigquery.Table(f"{landing}.stg_tml")
    stg_tml.schema = [
        bigquery.SchemaField("taxonomy_code", "STRING"),
        bigquery.SchemaField("taxonomy_description", "STRING"),
        bigquery.SchemaField("provider_type", "STRING"),
        bigquery.SchemaField("provider_type_number", "INT64"),
        bigquery.SchemaField("specialty_type", "STRING"),
        bigquery.SchemaField("specialty_type_number", "INT64"),
        bigquery.SchemaField("source_file", "STRING"),
        bigquery.SchemaField("ingested_at", "TIMESTAMP"),
    ]
    client.create_table(stg_tml, exists_ok=True)
    print("Created landing_medicaid_npi_dev.stg_tml")

    # Drop stg_doge to allow schema change (e.g. period_month DATE -> STRING for YYYY-MM format)
    try:
        client.delete_table(f"{landing}.stg_doge")
        print("Dropped existing stg_doge for schema update")
    except Exception:
        pass
    stg_doge = bigquery.Table(f"{landing}.stg_doge")
    stg_doge.schema = [
        bigquery.SchemaField("npi", "STRING"),
        bigquery.SchemaField("billing_tin", "STRING"),
        bigquery.SchemaField("servicing_tin", "STRING"),
        bigquery.SchemaField("hcpcs_code", "STRING"),
        bigquery.SchemaField("period_month", "STRING"),  # YYYY-MM format from HHS DOGE
        bigquery.SchemaField("beneficiary_count", "INT64"),
        bigquery.SchemaField("claim_count", "INT64"),
        bigquery.SchemaField("total_paid", "FLOAT64"),
        bigquery.SchemaField("state", "STRING"),
    ]
    client.create_table(stg_doge, exists_ok=True)
    print("Created landing_medicaid_npi_dev.stg_doge")

    stg_ppl = bigquery.Table(f"{landing}.stg_ppl")
    stg_ppl.schema = [
        bigquery.SchemaField("npi", "STRING"),
        bigquery.SchemaField("application_date", "DATE"),
        bigquery.SchemaField("status", "STRING"),
        bigquery.SchemaField("source_file", "STRING"),
        bigquery.SchemaField("ingested_at", "TIMESTAMP"),
    ]
    stg_ppl.description = "FL Pending Provider List. Providers in enrollment pipeline. Load from AHCA portal."
    client.create_table(stg_ppl, exists_ok=True)
    print("Created landing_medicaid_npi_dev.stg_ppl")

    # Mart: org_master + org_affiliations for manual assignment of billing NPIs to orgs (chat UI, etc.)
    mart = f"{PROJECT}.mobius_medicaid_npi_dev"

    org_master = bigquery.Table(f"{mart}.org_master")
    org_master.schema = [
        bigquery.SchemaField("org_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("org_name", "STRING"),
        bigquery.SchemaField("created_at", "TIMESTAMP"),
        bigquery.SchemaField("updated_at", "TIMESTAMP"),
    ]
    org_master.description = "Master orgs. Chat/admin assigns billing NPIs to org_id via org_affiliations."
    client.create_table(org_master, exists_ok=True)
    print("Created mobius_medicaid_npi_dev.org_master")

    org_affiliations = bigquery.Table(f"{mart}.org_affiliations")
    org_affiliations.schema = [
        bigquery.SchemaField("org_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("billing_npi", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("created_at", "TIMESTAMP"),
    ]
    org_affiliations.description = "Assignment of billing NPIs to org_id. Populated by chat/admin."
    client.create_table(org_affiliations, exists_ok=True)
    print("Created mobius_medicaid_npi_dev.org_affiliations")

    print("Done.")

if __name__ == "__main__":
    main()
