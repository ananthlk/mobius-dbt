# B2 Address Validation — Logic in Plain English

**What B2 checks:** Whether the provider’s **practice location** address and **mailing** address in NPPES are the same or different. Both come from NPPES only (no PML).

**Use:** Informational only. B2 does **not** affect status (Green/Yellow/Red) or readiness score. Many providers legitimately have different mailing vs practice addresses (e.g. PO box for mail, physical site for practice).

---

## 1. Source data

**Table:** `nppes_fl` (Florida NPIs from NPPES).

**Practice location (business practice):**
- `provider_first_line_business_practice_location_address`
- `provider_business_practice_location_address_city_name`
- `provider_business_practice_location_address_state_name`
- `provider_business_practice_location_address_postal_code`

**Mailing address:**
- `provider_first_line_business_mailing_address`
- `provider_business_mailing_address_city_name`
- `provider_business_mailing_address_state_name`
- `provider_business_mailing_address_postal_code`

---

## 2. B2 logic

1. Build a **normalized** string for each address: line 1 + city + state + ZIP (digits only), uppercased, trimmed, spaces collapsed.
2. **Flag B2** when:
   - practice normalized is non-empty, **and**
   - mailing normalized is non-empty, **and**
   - the two normalized strings are **not equal**.

So: **B2 = “practice and mailing addresses differ”** (both present and different). If either address is missing/blank, we do not set B2.

---

## 3. Output

From `npi_addresses_fl`:

| Column | Meaning | Used for status/readiness? |
|--------|---------|----------------------------|
| `b2_mailing_vs_practice_mismatch` | true when practice ≠ mailing (both non-empty) | **No** — info only |

`address_validation_fl` passes it through as `issue_b2`. The report shows it for context but does not use it for Green/Yellow/Red or readiness score (unlike B1 and B3).

---

## 4. Summary

| Rule | Severity | Condition |
|------|----------|-----------|
| Practice vs mailing | Info only | Both addresses non-empty and normalized strings differ → `b2_mailing_vs_practice_mismatch` = true |

---

## 5. Why “info only”

Different mailing vs practice is common (e.g. PO box vs physical location). It does not by itself indicate a Florida Medicaid enrollment or claim issue. B1 (NPPES vs PML ZIP+4) and B3 (address vs org mode) are used for readiness; B2 is for awareness and follow-up only.
