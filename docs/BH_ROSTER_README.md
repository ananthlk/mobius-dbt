# FL Behavioral Health Roster

One comprehensive table (`bh_roster`) for chat. Follows **B0 logic** (see `docs/B0_ROSTER_AND_ORG_STRUCTURE_PLAN.md`): union of **address-based** (ZIP+9 co-location) + **billing-NPI-based** (DOGE claims: servicing NPIs under each billing org).

## Models

| Model | Purpose |
|-------|---------|
| **stg_bh_taxonomy_whitelist** | BH taxonomy codes from NUCC (Mental Health, Psychiatry, etc.). |
| **nucc_lookup** | Full NUCC taxonomy lookup (code + classification) for org, site, provider. |
| **bh_provider_locations** | Individual FL practitioners with full NPPES and taxonomy details. |
| **bh_roster** | Org + servicing NPI links with org name, site address, taxonomy, NPPES, PML, billing, explanations. |

## bh_roster columns (chat-facing)

| Column | Description |
|--------|-------------|
| org_npi, org_name, source_type | BH organization; source_type = `address` (ZIP+9 match) or `billing_npi` (DOGE claims) |
| org_taxonomy_code, org_taxonomy_classification, org_taxonomy_bh_grouping | Org NUCC taxonomy + BH grouping |
| site_address_line_1, site_city, site_state, site_zip, site_zip9, site_taxonomy_* | Site location and taxonomy (site = org address) |
| servicing_npi, servicing_provider_name, specialty | Servicing provider |
| provider_taxonomy_code, provider_taxonomy_classification, provider_taxonomy_bh_grouping | Provider NUCC taxonomy + BH grouping |
| nppes_practice_line_1, nppes_practice_city, ... | NPPES practice address |
| nppes_mailing_line_1, nppes_mailing_city, ... | NPPES mailing address |
| pml_*, in_pml | PML enrollment and address |
| total_claims_3yr, total_spend_3yr, avg_beneficiaries_per_month_3yr | DOGE pair-level (org+servicing) last 3 years |
| months_with_claims_3yr, last_active_month | Activity recency |
| npi_total_claims_3yr, npi_total_spend_3yr, npi_avg_beneficiaries_per_month_3yr | DOGE servicing NPI rollup (across all orgs) |
| nppes_practice_address_complete, nppes_pml_zip9_match, org_site_exact_match | Consistency flags |
| confidence_score | 0–100 |
| roster_explanation | Plain-language narrative for chat |

DOGE: Last 3 years = CLAIM_FROM_MONTH >= 202202. Code-level (HCPCS) can be added later.

## Run

```bash
# Prereqs: landing_medicaid_npi_dev has stg_nucc_taxonomy, stg_pml, medicaid-provider-spending
uv run dbt run --select marts.bh_roster
```

## Troubleshooting

### PML not populating (in_pml always false, pml_* null)

1. **Load PML** – `stg_pml` must be loaded from FL AHCA CSV:
   ```bash
   uv run python scripts/load_medicaid_landing.py --pml /path/to/pml.csv
   ```
2. **Schema alignment** – If the table was created before adding `program_state`/`product`:
   ```bash
   BQ_PROJECT=mobius-os-dev ./scripts/create_medicaid_tables.sh  # recreates with full schema
   # Or ALTER TABLE to add program_state STRING, product STRING, taxonomy_code STRING
   ```
3. **NUCC loaded** – For taxonomy classification: `uv run python scripts/load_nucc_to_landing.py`

## Replaces

- `tmp_provider_locations` → `bh_provider_locations` (with full NPPES + taxonomy details)
- `final_cmhc_roster` → `bh_roster` (comprehensive, self-sufficient)
