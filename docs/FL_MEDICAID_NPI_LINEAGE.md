# FL Medicaid NPI: Landing → Report Lineage

Schematic of data flow from landing sources through all transformations to the final report models.

---

## Landing / Source Tables

| Source | Table | Description |
|--------|-------|-------------|
| **nppes_public** | npi_optimized | NPI provider data (bigquery-public-data) |
| **nppes_public** | npi_raw | Raw NPI data |
| **landing_medicaid_npi** | stg_pml | Provider Master List (AHCA) |
| **landing_medicaid_npi** | stg_tml | Taxonomy Master List |
| **landing_medicaid_npi** | stg_ppl | Pending Provider List |
| **landing_medicaid_npi** | stg_doge | DOGE Medicaid Provider Spending |
| **landing_medicaid_npi** | medicaid_provider_spending | Raw HHS Medicaid Provider Spending |
| **landing_medicaid_npi** | stg_nucc_taxonomy | NUCC taxonomy (load via `scripts/load_nucc_to_landing.py`) |

Defined in: `models/sources/medicaid_sources.yml`

---

## Schematic (Mermaid)

```mermaid
flowchart TB
    subgraph LANDING [Landing Sources]
        NPPES[nppes_public.npi_optimized]
        PML[stg_pml]
        TML[stg_tml]
        PPL[stg_ppl]
        DOGE[stg_doge / medicaid_provider_spending]
        NUCC[stg_nucc_taxonomy]
    end

    subgraph FOUNDATION [Foundation]
        nppes_providers[nppes_providers]
        medicaid_provider_ids[medicaid_provider_ids]
        fl_medicaid_taxonomy[fl_medicaid_taxonomy]
        billing_servicing_pairs[billing_servicing_pairs]
        billing_patterns[billing_patterns]
        nucc_taxonomy[nucc_taxonomy]
    end

    subgraph FL [FL-Scoped]
        nppes_fl[nppes_fl]
        nppes_tax_unpiv[nppes_taxonomies_unpivoted_fl]
        bsp_fl[billing_servicing_pairs_fl]
        tax_prev[taxonomy_prevalence_fl]
        tax_combo[taxonomy_combo_turf_fl]
        tax_hcpcs[taxonomy_hcpcs_volume_fl]
        tax_hcpcs_idx[taxonomy_hcpcs_volume_indexed_fl]
        npi_addr[npi_addresses_fl]
        addr_val[address_validation_fl]
        tax_val[taxonomy_validation_fl]
        orgs[organizations]
        pr_read[provider_readiness]
        pr_summary[provider_readiness_summary]
    end

    subgraph ANALYSIS [Analysis Marts]
        cov[provider_taxonomy_coverage_fl]
        missed[provider_missed_opportunities_fl]
        danger[provider_danger_opportunities_fl]
    end

    subgraph FINAL [Final Report]
        PRR[provider_readiness_report]
        PRES[provider_readiness_executive_summary]
        PPS[provider_propensity_score_fl]
    end

    NPPES --> nppes_providers
    NPPES --> nppes_fl
    PML --> medicaid_provider_ids
    PML --> fl_medicaid_taxonomy
    PML --> npi_addr
    TML --> fl_medicaid_taxonomy
    PPL --> pr_read
    DOGE --> billing_servicing_pairs
    NUCC --> nucc_taxonomy

    nppes_providers --> nppes_fl
    nppes_fl --> nppes_tax_unpiv
    nppes_fl --> npi_addr
    nppes_fl --> bsp_fl
    billing_servicing_pairs --> bsp_fl
    nppes_fl --> orgs
    bsp_fl --> orgs

    nppes_tax_unpiv --> tax_prev
    nppes_tax_unpiv --> tax_combo
    bsp_fl --> tax_hcpcs
    nppes_tax_unpiv --> tax_hcpcs
    tax_hcpcs --> tax_hcpcs_idx

    npi_addr --> addr_val
    bsp_fl --> addr_val
    bsp_fl --> tax_val
    fl_medicaid_taxonomy --> tax_val
    nppes_tax_unpiv --> tax_val
    nppes_fl --> tax_val
    tax_hcpcs_idx --> tax_val
    PML --> tax_val

    bsp_fl --> pr_read
    NPPES --> pr_read
    PML --> pr_read
    pr_read --> pr_summary

    tax_prev --> cov
    nppes_tax_unpiv --> cov
    tax_prev --> missed
    tax_hcpcs --> missed
    nppes_tax_unpiv --> missed
    tax_hcpcs_idx --> danger
    nppes_tax_unpiv --> danger
    bsp_fl --> danger

    pr_read --> PRR
    addr_val --> PRR
    tax_val --> PRR
    orgs --> PRR
    NPPES --> PRR

    PRR --> PRES
    pr_summary --> PRES
    PRR --> PPS
```

---

## Hierarchical Outline

```
LANDING
├── nppes_public.npi_optimized, npi_raw
└── landing_medicaid_npi
    ├── stg_pml (Provider Master List)
    ├── stg_tml (Taxonomy Master List)
    ├── stg_ppl (Pending Provider List)
    ├── stg_doge / medicaid_provider_spending
    └── stg_nucc_taxonomy

FOUNDATION
├── nppes_providers          ← npi_optimized
├── medicaid_provider_ids    ← stg_pml
├── fl_medicaid_taxonomy     ← stg_tml
├── billing_servicing_pairs  ← stg_doge / medicaid_provider_spending
├── billing_patterns
└── nucc_taxonomy            ← stg_nucc_taxonomy  [nucc_taxonomy.sql]

FL-SCOPED
├── nppes_fl                          ← nppes_optimized (FL filter)
├── nppes_taxonomies_unpivoted_fl     ← nppes_fl
├── billing_servicing_pairs_fl        ← billing_servicing_pairs, nppes_fl
├── taxonomy_prevalence_fl            ← nppes_taxonomies_unpivoted_fl
├── taxonomy_combo_turf_fl            ← nppes_taxonomies_unpivoted_fl
├── taxonomy_hcpcs_volume_fl          ← billing_servicing_pairs_fl, nppes_taxonomies_unpivoted_fl
├── taxonomy_hcpcs_volume_indexed_fl  ← taxonomy_hcpcs_volume_fl
├── npi_addresses_fl                  ← nppes_fl, stg_pml  [npi_addresses_fl.sql]
├── address_validation_fl             ← npi_addresses_fl, billing_servicing_pairs_fl
├── taxonomy_validation_fl            ← billing_servicing_pairs_fl, fl_medicaid_taxonomy, nppes_*, taxonomy_hcpcs_volume_indexed_fl, stg_pml  [taxonomy_validation_fl.sql]
├── organizations                     ← billing_servicing_pairs_fl, npi_optimized  [organizations.sql]
├── provider_readiness                ← billing_servicing_pairs, nppes, stg_pml, stg_ppl
└── provider_readiness_summary        ← provider_readiness

ANALYSIS MARTS
├── provider_taxonomy_coverage_fl     [provider_taxonomy_coverage_fl.sql]
├── provider_missed_opportunities_fl  [provider_missed_opportunities_fl.sql]
└── provider_danger_opportunities_fl  [provider_danger_opportunities_fl.sql]

FINAL REPORT
├── provider_readiness_report         [provider_readiness_report.sql]
│   refs: provider_readiness, address_validation_fl, taxonomy_validation_fl, organizations, npi_optimized
├── provider_readiness_executive_summary  [provider_readiness_executive_summary.sql]
│   refs: provider_readiness_report, provider_readiness_summary
└── provider_propensity_score_fl      [provider_propensity_score_fl.sql]
    refs: provider_readiness_report
```

---

## Run Order (Build Report)

```bash
# 1. Load NUCC (if stg_nucc_taxonomy empty)
python scripts/load_nucc_to_landing.py

# 2. Build full report chain
dbt run --select +provider_readiness_report +provider_readiness_executive_summary +provider_propensity_score_fl

# With optional PML columns (when available)
dbt run --select +provider_readiness_report --vars '{"use_pml_address": true, "use_pml_taxonomy": true}'
```

---

## Models Implemented in This Project

| Model | File |
|-------|------|
| nucc_taxonomy | nucc_taxonomy.sql |
| organizations | organizations.sql |
| npi_addresses_fl | npi_addresses_fl.sql |
| taxonomy_validation_fl | taxonomy_validation_fl.sql |
| provider_readiness_report | provider_readiness_report.sql |
| provider_readiness_executive_summary | provider_readiness_executive_summary.sql |
| provider_propensity_score_fl | provider_propensity_score_fl.sql |
| provider_taxonomy_coverage_fl | provider_taxonomy_coverage_fl.sql |
| provider_missed_opportunities_fl | provider_missed_opportunities_fl.sql |
| provider_danger_opportunities_fl | provider_danger_opportunities_fl.sql |

Upstream models (nppes_fl, billing_servicing_pairs_fl, provider_readiness, etc.) are expected to exist in the same project or a dbt package.
