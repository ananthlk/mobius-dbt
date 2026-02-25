# B6 — Integrated Report (Single Read Head)

**Purpose:** One detailed layer that exposes **all** logic and details from B0–B5. The front end and chat **only** query B6. They never need to know about or join B0–B5.

---

## 1. Single read head

- **Query by any of:** major **org_id**, **npi**, or **site_id** (sub_org / place).
- The API or front end passes one identifier; B6 returns full details for that org, NPI, or site.
- Chat / RAG can resolve questions by querying B6 with the identifier the user provides (org, NPI, or site).

---

## 2. What B6 contains (obfuscates B0–B5)

| Layer | What B6 exposes (detailed) |
|------|----------------------------|
| **B0** | Roster / org structure: `org_id`, `site_id` (sub_org_id), `npi`, `billing_npi`, `source_type` (address \| billing_npi), `associated_member_npis`, `tin` (when available). So for any org/site/NPI you see full roster context. |
| **B1** | NPPES vs PML alignment: `b1_status`, `b1_nppes_pml_mismatch`, `b1_zip9_match`, `b1_nppes_zip9`, `b1_pml_zip9`, sub-flags (line1 present, zip9 present, city/state match, street warning). |
| **B2** | Address info: `b2_mailing_vs_practice_mismatch`, practice and mailing addresses (line1, city, state, zip) so UI can show “mailing vs practice” without calling B2. |
| **B3** | Taxonomy alignment: `b3_status`, `b3_at_least_one_viable_in_fl`, `b3_no_viable_in_fl`, `b3_nppes_taxonomy_count`, `b3_fl_allowed_count`. |
| **B4** | Medicaid ID check: `b4_medicaid_id_count`, `b4_has_permissible_id`, `b4_no_medicaid_id_in_pml`, and the full Medicaid ID roster for that NPI (list or rows). |
| **B5** | Final alignment: Medicaid ID + NPI + taxonomy + **site** (service location). One combined status: e.g. `b5_status` (pass \| fail) and which of B1/B3/B4/site failed. |

B6 is **very detailed**: every status, flag, count, and address/taxonomy/Medicaid ID detail needed for UI and chat is on the row(s) returned for that org / NPI / site.

---

## 3. Lookup semantics

- **By org_id:** Return all rows where `org_id = :id` (or `billing_npi = :id` when org is billing-NPI). Each row = one (npi, site_id) in that org with full B0–B5 detail.
- **By npi:** Return all rows where `npi = :npi`. Each row = one org/site that NPI belongs to, with full B0–B5 detail.
- **By site_id:** Return all rows where `site_id = :id`. Each row = one NPI at that site with full B0–B5 detail.

So one denormalized “fact” row = (org_id, site_id, npi) + every B0–B5 field. Same NPI can appear on multiple rows (one per org/site).

---

## 4. B5 definition (Medicaid ID + NPI + taxonomy + site alignment)

- **B5** = combined rule: for a given NPI at a given site (service location), we require:
  - **NPI** present and valid.
  - **Medicaid ID** in PML and permissible (B4).
  - **Taxonomy** at least one viable in FL (B3).
  - **Site** = service location aligned (NPPES vs PML address, B1).

So `b5_status` = pass only when B1 (site), B3 (taxonomy), and B4 (Medicaid ID) all pass for that NPI/site. B6 computes and stores this so consumers don’t implement the rule.

---

## 5. Implementation notes

- **B6 model:** One view/table built by joining B0 roster list, npi_addresses_fl (B1/B2), b3_taxonomy_alignment_fl, b4_medicaid_id_roster_fl + b4_npi_medicaid_status_fl, and a small B5 step (AND of B1/B3/B4 pass).
- **Grain:** One row per (npi, org_id, site_id) with site_id = sub_org_id (or null when source is billing_npi only). All B0–B5 columns are on that row.
- **Medicaid ID roster:** For each row, either include an array of (medicaid_provider_id, b4_permissible) or a separate child table/key that B6 documents so the API can return “all Medicaid IDs for this NPI” from one B6-backed call.

---

## 6. Summary

| Item | Description |
|------|-------------|
| **Read head** | Query by **org_id**, **npi**, or **site_id**; get full details. |
| **Detail level** | Very detailed; all B0–B5 statuses, flags, addresses, taxonomies, Medicaid IDs. |
| **Consumers** | Front end and chat use **only B6**; B0–B5 are obfuscated (implementation detail). |
| **B5** | Medicaid ID + NPI + taxonomy + site alignment; single combined status in B6. |
| **B6** | Integrated report table/view; one row per (npi, org_id, site_id) with every B0–B5 field. |
