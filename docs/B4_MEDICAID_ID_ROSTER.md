# B4 — Medicaid ID Roster and Validation

**Goal:** For each NPI, maintain a **roster of all Medicaid IDs** (from PML) — **multiple IDs per NPI are expected**. Flag **permissible** rows (in PML, contract valid), **flag if NPI has no Medicaid ID in PML**, and treat **NPPES Medicaid ID** as **info only** (whether their ID is updated in NPPES).

---

## 1. Roster of Medicaid IDs per NPI (multiple IDs allowed)

**Source:** PML (`stg_pml`). An NPI can have **multiple** Medicaid IDs (e.g. different programs, locations, or history). We do **not** assume one Medicaid ID per NPI.

- **Roster:** For each NPI, the **list of all** Medicaid IDs that appear in PML for that NPI.
- **Grain:** One row per (NPI, Medicaid ID) from PML. So multiple rows per NPI when PML has multiple Medicaid IDs for that NPI.

**PML columns used (when present):**

- `npi`
- `medicaid_provider_id` — the Florida Medicaid provider ID for this NPI
- `contract_effective_date`, `contract_end_date` — to derive “permissible” (e.g. current or overlapping a reference date)
- Other columns (address, taxonomy, etc.) as needed for reporting

---

## 2. Flag: permissible (exists in PML, correct)

- **Per row (NPI, Medicaid ID):** “Permissible” = this (NPI, Medicaid ID) **exists in PML** and, if desired, the contract is valid (e.g. effective date ≤ ref_date and end date is null or ≥ ref_date).
- So: **permissible = in PML** (and optionally **contract valid**). Rows not in PML are not in the roster; we can also flag “in roster but contract expired” if we want a separate status.

---

## 3. NPPES “other provider identifier” for Medicaid — **info only**

- NPPES allows providers to report **other provider identifiers**, including **Medicaid** (issuer = MEDICAID, with optional state).
- **Use:** **Info only.** We report whether the provider’s Medicaid ID is **updated in NPPES** (i.e. NPPES Medicaid ID(s) match the roster). We do **not** use this for pass/fail or readiness; it’s for awareness and follow-up (e.g. “ID in PML but not yet in NPPES” or “NPPES has different ID”).
- When schema is available: join NPPES other-provider-identifier (type = MEDICAID, state = FL) to roster; add columns such as `nppes_medicaid_id_reported`, `nppes_medicaid_id_matches_roster` — **informational only**.

---

## 4. Outputs (model)

- **Roster table (e.g. `b4_medicaid_id_roster_fl`):**
  - One row per (npi, medicaid_provider_id) from PML.
  - Columns: `npi`, `medicaid_provider_id`, `permissible` (true if in PML and optionally contract valid), contract dates, and any other PML fields useful for reporting.
- **Optional NPPES validation columns** (when NPPES Medicaid ID columns exist):
  - For each NPI: whether NPPES reports a Medicaid ID; whether that ID is in the roster; and vice versa (roster ID present in NPPES).

---

## 5. Tests we do here

| Test | Severity | Meaning |
|------|----------|--------|
| **NPI has no Medicaid ID in PML** | Flag (fail) | NPI is in scope (e.g. FL NPPES or in report) but has **zero** rows in the roster — not enrolled / no Medicaid ID in PML. |
| **NPI has no permissible Medicaid ID** | Flag (fail) | NPI has at least one Medicaid ID in PML but **none** with a currently valid contract (all expired or not yet effective). |
| **NPPES Medicaid ID updated / matches roster** | **Info only** | Whether NPPES “other provider identifier” for Medicaid matches the roster; not used for pass/fail. |
| **Multiple Medicaid IDs per NPI** | Supported | Roster has one row per (npi, medicaid_provider_id); count or list is available for reporting. |

No other tests are defined for B4 at this time. Additional checks (e.g. specific program types, state restrictions) can be added later.

---

## 6. Models

### b4_medicaid_id_roster_fl (roster — multiple IDs per NPI)

- **Source:** `medicaid_provider_ids` (from `stg_pml`); requires `npi`, `medicaid_provider_id`, `contract_effective_date`, `contract_end_date`.
- **Grain:** One row per (npi, medicaid_provider_id). Multiple rows per NPI when PML has multiple Medicaid IDs.
- **Columns:** `npi`, `medicaid_provider_id`, `latest_contract_effective_date`, `latest_contract_end_date`, `b4_permissible` (true if any contract is currently valid).

### b4_npi_medicaid_status_fl (per-NPI flags)

- **Purpose:** For each NPI (e.g. in `nppes_fl`), flag whether they have any Medicaid ID in PML and any permissible ID.
- **Flags:** `b4_no_medicaid_id_in_pml` (true when NPI has zero roster rows), `b4_has_permissible_id` (at least one roster row with `b4_permissible`), `b4_medicaid_id_count`.
- **NPPES (future):** Add columns such as `nppes_medicaid_id_reported`, `nppes_medicaid_id_matches_roster` — **info only**.
