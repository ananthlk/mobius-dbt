# B3 Taxonomy Alignment, B4 Medicaid ID, and Final Rule

**Goal:** Answer “Is this NPI allowed to practice in Florida?” using **all** NPPES taxonomies (not just primary) and a Florida-allowed taxonomy set. Then add valid Medicaid ID (B4). The **final rule** is: **NPI + Medicaid ID + taxonomy + service location** alignment. Everything before this (B1 address, B2 mailing vs practice, B3 taxonomy, B4 Medicaid ID) leads here.

---

## 1. Why not just primary taxonomy?

- The question is: **Is this NPI allowed to practice in Florida?** For that, the **specific taxonomy** they use must be **registered in NPPES** (could be **any** of their taxonomies, not only slot 1).
- They must have **at least one viable taxonomy that is valid in FL** (e.g. on the FL Medicaid / TML list).
- Examples we need to support:
  - NPI has 5 taxonomies in NPPES but only 3 are “allowed in FL” — are the other 2 allowed or not in FL?
  - NPI has NPPES taxonomies but **none** are allowed in Florida.
- So we need a **union** view: NPI’s taxonomies (all slots) vs “allowed in FL” set, with clear flags per taxonomy and per NPI.

---

## 2. B3 — Taxonomy alignment (new)

**Scope:** All NPPES taxonomy slots (e.g. 1–15), not just primary. Compare to “allowed in Florida” (e.g. TML / FL Medicaid taxonomy list).

### 2.1 Inputs

- **NPPES:** All taxonomy codes for the NPI (`nppes_taxonomies_unpivoted_fl` or equivalent: one row per (NPI, taxonomy_code), possibly with `is_primary`).
- **FL allowed set:** Taxonomy codes that are valid / allowed in Florida (e.g. from `fl_medicaid_taxonomy` or TML). Call this the **“allowed in FL”** set.

### 2.2 Union and categories

For each NPI we can build:

- **Union of taxonomies:** All distinct taxonomy codes that appear in (a) NPPES for this NPI, and (b) FL allowed set (or optionally PML/roster for this NPI). For explanation we can also define:
  - **In NPPES only:** registered in NPPES for this NPI, not in FL allowed set.
  - **In FL only:** in FL allowed set but not in NPPES for this NPI (missing from NPPES).
  - **In both:** present in NPPES for this NPI and in FL allowed set.

### 2.3 Flags / scores (per NPI or per NPI + taxonomy)

| Flag / score | Meaning |
|--------------|--------|
| **allowed_in_fl** | Taxonomy is in the FL allowed set (TML / FL Medicaid list). |
| **not_allowed_in_fl** | Taxonomy is not in the FL allowed set. |
| **allowed_but_missing_in_fl** | Could mean: in NPPES but not in FL list (so “registered in NPPES but not allowed in FL”), or the inverse depending on naming. Clarify as: **registered_but_not_allowed_in_fl** = in NPPES for this NPI but not in FL allowed set. |
| **allowed_but_missing_in_nppes** | In FL allowed set but not registered in NPPES for this NPI (NPI could add this taxonomy in NPPES). |
| **at_least_one_viable_in_fl** | NPI has at least one taxonomy that is in the FL allowed set (so they have a viable FL taxonomy). |
| **no_viable_in_fl** | NPI has NPPES taxonomies but **none** are in the FL allowed set. |

Per-**NPI** summary:

- **b3_has_at_least_one_viable_taxonomy** (bool): at least one NPPES taxonomy is allowed in FL.
- **b3_all_nppes_taxonomies_not_allowed_in_fl** (bool): NPI has NPPES taxonomies but none allowed in FL.
- **b3_nppes_taxonomy_count**, **b3_fl_allowed_count**, **b3_in_both_count** (counts for reporting).

Per-**NPI + taxonomy** (for detail):

- **allowed_in_fl**, **registered_but_not_allowed_in_fl**, **in_nppes**, **in_fl_list**, etc.

### 2.4 Relation to existing “B3” in code

- **Current code:** “B3” = servicing NPI’s **address** ≠ org mode address (address outlier within billing org). That stays as-is for address; it can be renamed later (e.g. “address org outlier”) if we want B3 to mean only taxonomy.
- **New B3 (this doc):** B3 = **taxonomy alignment** (NPI’s taxonomies vs FL allowed; union; allowed / not allowed / missing; at least one viable in FL). Implementation will add a dedicated model or layer for this.

---

## 3. B4 — Valid Medicaid ID (new)

- **Question:** Does this NPI have a **valid Medicaid ID number** (e.g. enrolled in FL Medicaid, ID on file)?
- **Inputs:** PML, PPL, or other enrollment source that provides Medicaid ID / enrollment state.
- **Output:** Flag(s) such as **has_valid_medicaid_id**, or **medicaid_id_status** (valid / missing / expired / pending).
- Implementation details (column names, sources) to be defined when we add B4.

---

## 4. Final rule: NPI + Medicaid ID + taxonomy + service location

Once we have:

- **B1** — Address alignment (NPPES vs PML service location, ZIP+9).
- **B2** — Mailing vs practice (info only).
- **B3** — Taxonomy alignment (all NPPES taxonomies vs FL allowed; at least one viable in FL; flags above).
- **B4** — Valid Medicaid ID.

the **final rule** is:

**NPI + Medicaid ID + taxonomy + service location** alignment.

- In other words: a valid combination is (NPI, Medicaid ID, taxonomy, service location) where:
  - Service location is aligned (B1),
  - At least one taxonomy is allowed in FL (B3),
  - Medicaid ID is valid (B4),
  - and any other rules we add (e.g. that taxonomy is registered in NPPES for that NPI).

Everything before this (B1, B2, B3, B4) leads to being able to say whether we have a valid **NPI + Medicaid ID + taxonomy + service location** combination.

---

## 5. Implementation order

1. **B1** — Address only (done; taxonomy removed from B1).
2. **B3** — Taxonomy alignment: union NPPES (all slots) vs FL allowed; flags (allowed in FL, not allowed, registered but not allowed in FL, at least one viable, none viable). Implement when ready.
3. **B4** — Valid Medicaid ID. Implement when ready.
4. **Final rule** — Combine B1 + B3 + B4 (+ service location from B1) into “NPI + Medicaid ID + taxonomy + service location” validity.

---

## 6. Summary

| Layer | Scope | Purpose |
|-------|--------|---------|
| **B1** | Address | NPPES vs PML service location (ZIP+9). |
| **B2** | Address | Mailing vs practice (info only). |
| **B3** (new) | Taxonomy | All NPPES taxonomies vs FL allowed; union; allowed / not allowed / missing; at least one viable in FL. |
| **B4** (new) | Medicaid ID | Has valid Medicaid ID number. |
| **Final** | All | NPI + Medicaid ID + taxonomy + service location alignment. |
