# B3 Address Validation — Logic in Plain English

**What B3 checks:** Whether the **servicing NPI’s practice address** matches the **typical (most common) practice address** for the **billing org** they belong to. It flags servicing NPIs whose address is an “outlier” within that org.

**Use:** B3 **does** affect status (Green/Yellow/Red) and readiness score (same 15-point address bucket as B1). It helps spot possible data issues or providers at a different physical location than the rest of the org.

---

## 1. Context

- **Billing org:** Identified by `billing_npi` in `billing_servicing_pairs_fl`. One billing NPI has many **servicing NPIs** (the NPIs that actually render service and appear on claims).
- **Practice address:** From NPPES, normalized (line 1 + city + state + ZIP digits, uppercased, trimmed) — same `practice_normalized` as in `npi_addresses_fl`.

---

## 2. B3 logic

1. **Per billing org:** Among all servicing NPIs under that `billing_npi`, take each distinct `practice_normalized` and count how many servicing NPIs have it.
2. **Mode address:** For each billing org, the **mode address** is the `practice_normalized` that appears most often (the “typical” address for that org). Ties are broken by a deterministic ordering (e.g. `row_number() ... order by npi_count desc`).
3. **Flag B3** for a given (billing_npi, servicing_npi) when:
   - the servicing NPI has a non-null, non-empty `practice_normalized`, **and**
   - the org has a non-null `mode_address`, **and**
   - the servicing NPI’s `practice_normalized` **≠** the org’s `mode_address`.

So: **B3 = “this servicing NPI’s practice address is different from the most common practice address for this billing org.”**

---

## 3. Where it’s computed

B3 is **not** in `npi_addresses_fl` (that model is NPI-level only). It’s computed in **`address_validation_fl`**, which:

- Joins `billing_servicing_pairs_fl` (pairs) to `npi_addresses_fl` (addresses per NPI).
- Builds **org mode address** per `billing_npi` (most common `practice_normalized` among that org’s servicing NPIs).
- Sets `issue_b3 = true` when the servicing NPI’s address ≠ org mode address (with the non-null checks above).

---

## 4. Output

From `address_validation_fl` (and then the report):

| Column   | Meaning                                                                 | Used for status/readiness? |
|----------|-------------------------------------------------------------------------|----------------------------|
| `issue_b3` | true when servicing NPI’s practice address ≠ org’s mode (typical) address | **Yes** — same as B1 for status and readiness |

---

## 5. Summary

| Rule              | Severity | Condition |
|-------------------|----------|-----------|
| Address vs org mode | Severe (for scoring) | Servicing NPI has address, org has mode address, and they differ → `issue_b3` = true |

---

## 6. Why it matters

If most servicing NPIs under an org share one address (e.g. main clinic) and a few have a different address (e.g. different site or data entry error), B3 flags those few. That supports cleanup (wrong address?) or intentional multi-site tracking, and aligns with the rule that address affects readiness along with B1.
