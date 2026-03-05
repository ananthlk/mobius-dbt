# FL Medicaid NPI: Step Outputs Specification

**Principle:** Each step (step1–step9) is a **table** that is **self-sufficient**. The front end can query any step table directly and get org name, relevant details, and plain-language explanations without joining to other tables.

---

## Step Overview

| Step | Purpose | Grain | Front-end use |
|------|---------|-------|---------------|
| **step1** | Roster: orgs, sites, NPIs | One row per (org_id, sub_org_id, npi) | "Who is in the roster?" Org tree, site locations, provider list |
| **step2** | Address validation | One row per (billing_npi, servicing_npi) | "What address issues exist?" NPPES vs PML, mailing vs practice, B3 outlier |
| **step3** | Enrollment status | One row per roster row | "Who is enrolled?" in_nppes, in_pml, eligible_today, eligible_3mo |
| **step4** | Raw address flags | One row per (billing_npi, servicing_npi) | Lightweight address issue flags (B1, B2, B3, orphan) |
| **step5** | Medicaid ID status | One row per NPI | "Does NPI have Medicaid ID?" b4 counts and flags |
| **step6** | Taxonomy alignment | One row per NPI | "Is NPI taxonomy FL-allowed?" B3 status |
| **step7** | Taxonomy validation | One row per (billing_npi, servicing_npi) | C1–C4, D, F taxonomy issues with org/provider context |
| **step8** | Integrated report (B6) | One row per roster row | Single read: B1–B5, org name, site address, pass/fail |
| **step9** | Provider readiness report | One row per (billing_npi, servicing_npi) | Status flag, score, recommendations, full addresses |

---

## step1: Roster

**Purpose:** Master roster of orgs, sites (sub-locations), and NPIs. Self-sufficient for org tree and site address display.

**Materialized:** table

**Columns:**
| Column | Type | Description |
|--------|------|-------------|
| org_id | string | Organization ID (facility NPI or billing NPI) |
| sub_org_id | string | Site/location ID (null for billing_npi-only) |
| npi | string | Provider NPI |
| source_type | string | 'address' or 'billing_npi' |
| billing_npi | string | Billing NPI (null for address-based) |
| associated_member_npis | array&lt;string&gt; | Other NPIs at same site/org |
| **org_name** | string | Organization display name (from NPPES or org) |
| **site_address_line_1** | string | Site street address |
| **site_city** | string | Site city |
| **site_state** | string | Site state |
| **site_zip5** | string | Site ZIP5 |
| **site_zip9** | string | Site ZIP+4 |
| **npi_provider_name** | string | NPI provider/org name |
| **step_explanation** | string | Plain-language: "Roster row for [org] at site [address]. Source: address-based facility match / billing NPI group." |

---

## step2: Address Validation

**Purpose:** Address validation report. One place for billing/servicing, addresses, issues, and recommendations.

**Materialized:** table (already)

**Columns:** billing_org_name, servicing_provider_name, npi practice/mailing addresses, PML service location, org typical address, b1_status_code, issue_b1/b2/b3, is_orphan, reason_b1/b2/b3/orphan, recommendation_b1/b2/b3/orphan.

**Step explanation:** Embedded in reason_* and recommendation_* columns.

---

## step3: Enrollment Status

**Purpose:** Enrollment (NPPES, PML, PPL) and eligibility (today, 3mo) per roster row.

**Materialized:** table

**Columns:**
| Column | Type | Description |
|--------|------|-------------|
| report_date | date | As-of date |
| org_id | string | |
| sub_org_id | string | |
| npi | string | |
| source_type | string | |
| billing_npi | string | |
| **org_name** | string | Organization display name |
| **npi_provider_name** | string | NPI provider name |
| in_nppes | bool | |
| in_pml | bool | |
| in_ppl | bool | |
| eligible_today | bool | |
| eligible_3mo | bool | |
| reason_today | string | e.g. 'ready', 'not_in_pml' |
| reason_3mo | string | |
| claim_count | int | |
| total_paid | float | |
| beneficiary_count | int | |
| **step_explanation** | string | "Enrollment status: [reason_today]. [reason_3mo] for 3‑month horizon." |

---

## step4: Raw Address Flags

**Purpose:** Lightweight address flags for (billing_npi, servicing_npi). Optional; step2 has full detail. If kept, add org_name + servicing_provider_name + brief explanation.

**Materialized:** table

**Columns:** billing_npi, servicing_npi, **billing_org_name**, **servicing_provider_name**, issue_b1, issue_b2, issue_b3, is_orphan, **step_explanation** (e.g. "B1: NPPES vs PML mismatch. B2: Mailing ≠ practice. B3: Org outlier. Orphan: no roster site.")

---

## step5: Medicaid ID Status

**Purpose:** Per-NPI Medicaid ID count and flags.

**Materialized:** table

**Columns:**
| Column | Type | Description |
|--------|------|-------------|
| npi | string | |
| **npi_provider_name** | string | From NPPES |
| b4_medicaid_id_count | int | |
| b4_has_permissible_id | bool | |
| b4_no_medicaid_id_in_pml | bool | |
| **step_explanation** | string | "NPI has [count] Medicaid ID(s) in PML. [Has/no] permissible ID." |

---

## step6: Taxonomy Alignment

**Purpose:** Per-NPI B3 taxonomy alignment vs FL TML.

**Materialized:** table

**Columns:**
| Column | Type | Description |
|--------|------|-------------|
| npi | string | |
| **npi_provider_name** | string | From NPPES |
| b3_nppes_taxonomy_count | int | |
| b3_fl_allowed_count | int | |
| b3_at_least_one_viable_in_fl | bool | |
| b3_no_viable_in_fl | bool | |
| b3_status | string | 'pass', 'no_nppes_taxonomy', 'no_viable_in_fl' |
| **step_explanation** | string | "Taxonomy: [b3_status]. [count] FL-allowed of [total] NPPES taxonomies." |

---

## step7: Taxonomy Validation

**Purpose:** C1–C4, D, F taxonomy issues per (billing_npi, servicing_npi) with org/provider context.

**Materialized:** table

**Columns:** billing_npi, servicing_npi, **billing_org_name**, **servicing_provider_name**, issue_c1, issue_c2, issue_c3, issue_c4, issue_d, issue_f, **step_explanation** (e.g. "C1: primary not in TML. C2: NPPES vs PML mismatch. C3: org outlier. C4: … D: … F: …").

---

## step8: Integrated Report (B6)

**Purpose:** Single comprehensive table. Query by org_id, npi, site_id, org_display_name, or npi_provider_name. B1–B5 pass/fail, org name, site address, practice/mailing, taxonomy, Medicaid ID.

**Materialized:** table (already)

**Columns:** org_display_name, npi_provider_name, site_address_line_1, site_city, site_state, site_zip5, site_zip9, b1_status, b3_status, b4_*, b5_pass, b5_fail_reason, etc. Self-sufficient.

---

## step9: Provider Readiness Report

**Purpose:** Report-ready: status flag (Green/Yellow/Red/Gray), readiness score, status messages, full addresses, issue flags, recommendations.

**Materialized:** table (already)

**Columns:** billing_org_name, servicing_provider_name, full addresses, status_flag, readiness_score, status_message_today, status_message_3mo, issue_b1/b2/b3, issue_c1–c4/d/f. Self-sufficient.

---

## bh_roster_readiness (roster-level readiness)

**Purpose:** Medicaid NPI initiative checks per bh_roster row. Self-sufficient for frontend; each check has pass/fail and explanation.

**Materialized:** table

**Grain:** One row per (org_npi, servicing_npi).

**Checks:**
| Check | Pass condition | Explanation (fail) |
|-------|----------------|--------------------|
| check_1_npi_in_pml | NPI in PML | "NPI is not in PML. Provider must be enrolled in Florida Medicaid to bill." |
| check_2_zip9_valid | NPPES practice ZIP+4 is 9 digits | "NPPES practice address has no ZIP+4" or "not 9 digits" |
| check_3_taxonomy_permitted | Provider taxonomy on FL TML | "Provider taxonomy X is not on the FL Medicaid Taxonomy Master List (TML)." |
| check_4_combo_medicaid_id | PML has valid row for NPI + taxonomy + ZIP9 | "PML has no matching row for NPI + taxonomy + ZIP+4 with valid contract" or "Cannot verify combo: NPI not in PML" |

**Columns:** org_npi, servicing_npi, site_address_*, check_1_* through check_4_*, readiness_all_pass, readiness_status (Ready | Not enrolled | Invalid address | Taxonomy not permitted | Combo mismatch), readiness_summary, **pml_credentialed_combos**, **suggested_action**, **suggested_taxonomies** (data-driven: top 3-5 co-occurring taxonomies with pct, e.g. "LCSW|30|150;MSW|15|80" — 30% of providers with roster taxonomy are also credentialed as LCSW).

---

## ghost_billing_fl

**Purpose:** Ghost billing = servicing NPIs that bill under the org (DOGE) but have weak address/roster match (confidence_score < 40).

**Materialized:** table

**Grain:** One row per (billing_npi, servicing_npi) with claims in last 12 months and confidence < 40.

**Columns:** billing_npi, servicing_npi, servicing_provider_name, confidence_score, claim_count, total_paid.

---

## Implementation Checklist

- [x] **step1:** Table; org_name, site address, npi_provider_name, step_explanation
- [x] **step2:** Table with org_name, addresses, reasons, recommendations
- [x] **step3:** Table; org_name, npi_provider_name, step_explanation
- [x] **step4:** Table; billing_org_name, servicing_provider_name, step_explanation
- [x] **step5:** Table; npi_provider_name, step_explanation
- [x] **step6:** Table; npi_provider_name, step_explanation
- [x] **step7:** Table; billing_org_name, servicing_provider_name, step_explanation
- [x] **step8:** Comprehensive (b6)
- [x] **step9:** Comprehensive (provider_readiness_report)
