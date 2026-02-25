# B1 Address Validation — Logic in Plain English

**Source of truth:** PML = Florida Medicaid (Provider Master List). NPPES = health plans and beyond Medicaid. We compare NPPES practice location to PML service location.

**Florida Medicaid rule (per plan guidelines — Simply Healthcare, Aetna Better Health, Sunshine Health):**
- The **NPI, taxonomy, first-line address, and 9-digit ZIP code (ZIP+4)** on each claim must match the Provider Master List (PML) **exactly**.
- For claims with date of service on or after March 1, 2022, the **9-digit ZIP** for the provider’s service location must be used; using only the 5-digit code may cause **claim denials**.
- Mismatches in address or zip code result in validation failures and claim denials. Providers should verify address and ZIP+4 in the Florida Medicaid Secure Web Portal (“Demographic Maintenance”) to match the PML exactly.

Use this doc to verify data loads and build your own queries to test.

---

## 1. Tables and columns

### 1.1 NPPES (national provider registry)

- **Table:** `bigquery-public-data.nppes.npi_optimized`
- **Used via:** `nppes_fl` (Florida only: `provider_business_practice_location_address_state_name = 'FL'`).
- **Columns for B1:**
  - `npi`
  - `provider_first_line_business_practice_location_address` → practice street (line 1)
  - `provider_business_practice_location_address_city_name` → practice city
  - `provider_business_practice_location_address_state_name` → practice state
  - `provider_business_practice_location_address_postal_code` → practice ZIP (5 or 9 digits)

---

### 1.2 PML (Florida Medicaid Provider Master List)

- **Table:** `{project}.landing_medicaid_npi.{stg_pml}`  
  - Dev: `mobius-os-dev.landing_medicaid_npi_dev.stg_pml`
- **Columns for B1:**
  - `npi`
  - `address_line_1` → PML service location street (line 1)
  - `city` → PML service location city
  - `state` → PML service location state
  - `zip` → PML service location ZIP (digits only, 5 or 9)
  - `zip_plus_4` → optional; used with `zip` when building 9-digit ZIP
  - `contract_effective_date` → used to pick one row per NPI (latest contract)

Taxonomy alignment is **B3** (see docs/B3_TAXONOMY_AND_FINAL_RULE.md).

---

### 1.3 Who gets B1

- **Table:** `billing_servicing_pairs_fl` (from DOGE / spending).
- **Columns:** `billing_npi`, `servicing_npi`.
- B1 is computed for every NPI in `nppes_fl`; the report uses it only for pairs in this table (servicing NPIs).

---

## 2. B1 logic in plain English

### 2.1 (1) Neither address can be null — **SEVERE**

- **NPPES:** Practice location (at least first line of address) must not be null or blank.
- **PML:** When we have a PML row for the NPI, the PML service location must have a non-empty line 1 and a **9-digit ZIP (ZIP+4)**.

We flag **severe** when:
- NPPES practice line 1 is null or empty, or
- We have PML data for the NPI but PML line 1 is empty or PML does not have a valid 9-digit ZIP (ZIP+4).

---

### 2.2 (2) 9-digit ZIP+4 must match exactly — **SEVERE**

Per Florida Medicaid: the **9-digit ZIP (ZIP+4)** must match the PML exactly. Using only the 5-digit code may cause claim denials.

- **NPPES** practice address must have a **9-digit ZIP** (from `provider_business_practice_location_address_postal_code`).
- **PML** service location must have a **9-digit ZIP** (from `zip` + `zip_plus_4` or a single 9-digit `zip`).
- The two **9-digit ZIPs must match exactly**.

We flag **severe** when both addresses are present but:
- NPPES does not have a 9-digit ZIP, or
- The NPPES 9-digit ZIP does not equal the PML 9-digit ZIP.

---

### 2.3 (3) Same street (line 1) — **WARNING only**

When both have a non-empty street line 1, we compare normalized line 1 (uppercase, trim, collapse spaces). If they differ, we set **warning** only. This does **not** drive status/readiness (like B2).

---

## 3. Output flags (model)

From `npi_addresses_fl`:

| Flag | Meaning | Used for status/readiness? |
|------|---------|----------------------------|
| `b1_nppes_pml_mismatch` | Severe: (1) or (2) above (address only) | Yes → becomes `issue_b1` in report |
| `b1_street_warning` | Warning: (4) street differs | No — info only |

`address_validation_fl` passes `b1_nppes_pml_mismatch` through as `issue_b1`. The report uses `issue_b1` for Green/Yellow/Red and readiness score.

### 3.1 B1 sub-flags and status (for follow-up and explanation)

To see **why** a row passed or failed B1 (e.g. missing ZIP+4 vs mismatch), use these columns from `npi_addresses_fl`:

| Column | Type | Meaning |
|--------|------|---------|
| **`b1_status`** | string | Single value: `pass` or exact fail reason (see below). Use for follow-up and explanations. |
| **`b1_nppes_zip9`** | string | 9-digit ZIP from NPPES practice (null if &lt; 9 digits). |
| **`b1_pml_zip9`** | string | 9-digit ZIP from PML (null if not available). |
| **`b1_nppes_practice_line1_present`** | bool | NPPES practice line 1 non-empty. |
| **`b1_pml_line1_present`** | bool | PML line 1 non-empty (when PML row exists). |
| **`b1_nppes_zip9_present`** | bool | NPPES has 9-digit ZIP. |
| **`b1_pml_zip9_present`** | bool | PML has 9-digit ZIP. |
| **`b1_zip9_match`** | bool | Both have 9-digit ZIP and they match exactly. |
| **`b1_city_match`** | bool | City match (both present and equal, normalized). |
| **`b1_state_match`** | bool | State match (both present and equal, normalized). |

**`b1_status` values:**

| Value | Severity | Meaning |
|-------|----------|---------|
| `pass` | — | NPPES practice line 1 present; PML (when present) has line 1 and ZIP+4; NPPES and PML 9-digit ZIPs match. |
| `fail_nppes_practice_line1_empty` | Severe | NPPES practice first line is null or blank. |
| `fail_pml_line1_empty` | Severe | PML row exists but PML address line 1 is empty. |
| `fail_pml_no_zip9` | Severe | PML row exists but PML has no valid 9-digit ZIP. |
| `fail_nppes_no_zip9` | Severe | NPPES has no 9-digit ZIP (PML has ZIP+4). |
| `fail_zip9_mismatch` | Severe | Both have 9-digit ZIPs but they do not match. |

---

## 4. Summary

| Rule | Severity | Condition |
|------|----------|------------|
| Neither address null | Severe | NPPES practice line 1 null/empty, or PML (when present) line 1 empty or no 9-digit ZIP |
| 9-digit ZIP+4 match | Pass | NPPES ZIP+4 = PML ZIP+4 exactly → no severe; missing or mismatch → severe |
| Same street (line 1) | Warning | Both have street; if different → `b1_street_warning` only |

---

## 5. Config

- **dbt var:** `use_pml_address`
  - `true`: use PML columns `address_line_1`, `city`, `state`, `zip`, `zip_plus_4` for B1.
  - `false`: no PML address; only “NPPES practice null” can cause severe; no ZIP/city/state or street checks.
---

## 6. B1 accuracy validation

**Script:** `scripts/validate_b1_accuracy.py` — run with `uv run python scripts/validate_b1_accuracy.py` from `mobius-dbt`. It prints:

- Counts: total, B1 pass (matched), B1 severe (missed).
- A sample of **matched** rows with NPPES practice vs PML service side-by-side (confirm 9-digit ZIP+4 match).
- A sample of **missed** rows when any exist (confirm they correctly fail: null/invalid address, missing ZIP+4, or ZIP+4 mismatch).

**Validation:** Run after model changes to confirm matched rows show aligned 9-digit ZIPs and missed rows show expected failures (e.g. 5-digit-only or mismatch).

---

## 7. Example test queries (BigQuery)

Replace `{project}`, `{dataset}`, `{landing_dataset}` (e.g. `mobius-os-dev`, `mobius_medicaid_npi_dev`, `landing_medicaid_npi_dev`).

**Counts from model:**
```sql
SELECT
  COUNTIF(b1_nppes_pml_mismatch) AS b1_severe,
  COUNTIF(b1_street_warning)     AS b1_street_warning,
  COUNT(*)                       AS total
FROM `{project}.{dataset}.npi_addresses_fl`;
```

**Side-by-side NPPES vs PML (ZIP+4):**
```sql
SELECT
  n.npi,
  n.provider_first_line_business_practice_location_address AS nppes_line1,
  n.provider_business_practice_location_address_city_name  AS nppes_city,
  n.provider_business_practice_location_address_state_name AS nppes_state,
  n.provider_business_practice_location_address_postal_code AS nppes_zip,
  p.address_line_1 AS pml_line1,
  p.city AS pml_city,
  p.state AS pml_state,
  p.zip AS pml_zip
FROM `{project}.{dataset}.nppes_fl` n
LEFT JOIN `{project}.{landing_dataset}.stg_pml` p
  ON CAST(p.npi AS STRING) = CAST(n.npi AS STRING)
WHERE n.npi IS NOT NULL
LIMIT 20;
```

**Servicing NPIs missing from NPPES (expect 0 if every record loaded):**
```sql
SELECT DISTINCT p.servicing_npi
FROM `{project}.{dataset}.billing_servicing_pairs_fl` p
LEFT JOIN `{project}.{dataset}.nppes_fl` n
  ON CAST(n.npi AS STRING) = CAST(p.servicing_npi AS STRING)
WHERE n.npi IS NULL
LIMIT 100;
```
