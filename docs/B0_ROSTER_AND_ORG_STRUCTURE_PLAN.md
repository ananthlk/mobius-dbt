# B0 — Roster Evaluation and Org Structure (Plan)

**Goal:** So we can **evaluate a given roster**, we first **assemble and expand on the org structure**: (1) **Facility master list** — entity type 2 **and** facility-related taxonomies; (2) **Address-based grouping** — one address per sub-org (suite can differ), propensity matching, NPIs can be in multiple sub-orgs; (3) **Billing-NPI-based grouping** — we do not have TIN (no DOGE); we use **billing NPI** as a second way to form groups (member NPIs under that billing NPI). We **union** address-based org/sub-org and billing-NPI-based member list. **Output:** org id, sub-org id, NPI, TIN (when available), associated member NPIs. Roster → match and flag discrepancies; no roster → still produce this list.

**Status:** Built. Models: b0_facility_master_fl, b0_sub_org_address_fl, b0_address_propensity_fl, b0_sub_org_members_fl, b0_billing_npi_members_fl, b0_roster_list_fl. Base refs: nppes_fl, billing_servicing_pairs, billing_servicing_pairs_fl, nppes_taxonomies_unpivoted_fl. Seed: b0_facility_taxonomy_codes.

---

## 1. Why this makes sense

- **Roster evaluation** needs a **reference**: “expected” org and sub-org structure (facilities, addresses, NPIs that belong there).
- **Facility-type NPIs** are a natural **anchor** (one per physical location / TIN in many cases); their **billing address** or **practice location** defines a “place.”
- **Other NPIs** (individuals, other entities) **associate** to that place by **address**: same billing address, same servicing address, or same ZIP+9 (or partial match).
- **Sub-org** = one “place” (e.g. one facility address) + all NPIs that match to that address at some strength. **Org** = one or more sub-orgs (e.g. same TIN, same parent, or same facility NPI).
- With this in place: **given roster** → match roster rows to this structure → flag discrepancies (missing, extra, wrong address, wrong org). **No roster** → we still output the assembled list (facilities, addresses, NPIs per sub-org/org).

---

## 2. Master list: facility-type NPIs

- **Source:** NPPES (or existing FL cohort). **Filter:** use **both**:
  - **Entity type = organization (2)**, and/or
  - **Taxonomies that may be facility-related** (e.g. facility taxonomy codes; we will identify or curate a list).
- **For each facility NPI we get:**
  - **Billing address** (if available).
  - **Practice location / servicing address** (business practice location).
  - **ZIP+9** (and ZIP5) for matching.
- This list is the **master** set of “places” we will use to form address-based sub-orgs.

---

## 3. Associating NPIs to facilities / addresses (sub-orgs)

- **For every NPI** (not just facilities), we want to **associate** them to one or more **sub-orgs** (i.e. to a facility + address, or to an address cluster).
- **How we associate:** **Address matching** between:
  - The NPI’s **billing address**, **practice location**, and/or **servicing address** (from NPPES, PML, or claims), and
  - The **facility’s billing/practice address** (or the address that defines the sub-org).
- We do **not** require exact string match; we use a **propensity (scoring) matching system** so we can rank and choose “best” sub-org and also detect partial matches.

---

## 4. Address propensity matching (same idea, no build yet)

**Strong match (high propensity):**

- Same **mailing address** (normalized): same line 1 + city + state + ZIP (or ZIP+9).
- Same **servicing address** (practice location): same line 1 + city + state + ZIP (or ZIP+9).
- **Share ZIP+9**: NPI’s address ZIP+9 equals facility/sub-org address ZIP+9 (even if line 1 differs).

**Partial / weaker match (for tie-break or “possible” association):**

- Same **ZIP5** only.
- Same **street** (line 1) normalized but different city/state or ZIP.
- Same **city + state** (and maybe ZIP5) but different street.
- Edit distance or similarity on normalized address string (optional).

**Output we want from matching:**

- For each (NPI, facility or sub-org) pair: a **match score** or **match type** (strong / partial) and which rule fired (mailing, servicing, ZIP+9, ZIP5, etc.).
- We can then **assign** each NPI to a “primary” sub-org (e.g. best strong match) and optionally keep secondary associations (other strong or partial matches) for discrepancy review.

---

## 5. Sub-org and org rollup

- **One address per sub-org:** Yes. One sub-org = one (facility, address) pair. If a facility has multiple addresses (e.g. different suite numbers), we get **multiple sub-orgs** (suite or line-1 difference can define a distinct sub-org). We do **not** have TIN from DOGE — we only have **billing NPI**.
- **Sub-org (address-based):** One “place” = one facility NPI + **one** address (billing or practice) + all NPIs that match that address at strong (or strong + selected partial) level. **NPIs can appear in multiple sub-orgs** (e.g. one NPI at two locations = two sub-org memberships).
- **Org:** Multiple sub-orgs roll up to one **org** when they share the same **facility NPI** (one facility, multiple addresses = one org, multiple sub-orgs).
- **Billing-NPI-based grouping (in addition to address):** Use **billing NPI** as another way to form groups. We do **not** rely on DOGE for TIN. So we have **two** dimensions and **union** them:
  1. **Address-based:** facility + address → sub-org → org (by facility NPI).
  2. **Billing-NPI-based:** billing NPI → group of “member” NPIs (servicing NPIs that bill under this billing NPI, from e.g. billing_servicing_pairs_fl). This is a separate list/grouping; we **union** it with the address-based structure so we can output and match on both (org id, sub-org id, and/or billing NPI group, NPI, associated member NPIs).
- Hierarchy: **Org → Sub-org(s) → NPIs** (address-based); **Billing NPI → member NPIs** (billing-based). Output includes both.

---

## 6. Roster evaluation (once structure exists)

- **Input:** A **roster** (e.g. list of NPI, or NPI + address, or NPI + Medicaid ID + taxonomy + address).
- **Process:** For each roster row, **match** to our assembled structure (by NPI, address, Medicaid ID, taxonomy as available):
  - Find the NPI in our org/sub-org list.
  - Compare roster address (if provided) to our address(es) for that NPI → propensity score.
  - Compare roster Medicaid ID to B4 roster, taxonomy to B3, address to B1 as needed.
- **Output:** **Discrepancies** = roster row not found, or NPI in different org/sub-org than expected, or address/taxonomy/Medicaid ID mismatch. We can flag: **missing from roster**, **extra on roster**, **address mismatch**, **org/sub-org mismatch**, etc.

---

## 7. Output: list of entries (with or without a roster)

- **Output fields:** Org id, sub-org id, NPI, TIN (if/when we have it — we do not have TIN from DOGE today), **associated member NPIs**. Plus address, and optionally B1/B3/B4 flags.
- **Without a roster:** We still **produce a list** of entries from the assembled structure:
  - **Address-based:** org id, sub-org id, (facility) NPI, address, associated member NPIs (NPIs that match this sub-org address).
  - **Billing-NPI-based:** billing NPI as group id, member NPIs (servicing NPIs under that billing NPI).
  - **Union** of both so each “entry” can be keyed by org id, sub-org id, NPI, and/or billing NPI, with associated member NPIs. TIN in output when available.
- That list is the **reference** for roster comparison or “expected” view.

---

## 8. Proposed sequence (no build yet)

1. **Define facility master list** — Source, filter (entity type, taxonomy), and columns (NPI, billing address, practice address, ZIP+9).
2. **Define address normalization** — Same as B1/B2 (line 1 + city + state + ZIP digits; normalized for matching).
3. **Define propensity rules** — Strong: same mailing, same servicing, same ZIP+9. Partial: same ZIP5, same street, same city+state, etc. Assign score or tier.
4. **Define sub-org** — One facility + one address + all NPIs that match that address at strong (and optionally partial) level.
5. **Define org** — Rollup of sub-orgs (e.g. by facility NPI or by billing NPI/TIN).
6. **Roster match and discrepancy** — How roster rows map to (org, sub-org, NPI); which discrepancies we flag.
7. **Output without roster** — Format of “list of entries” (org / sub-org / NPI / address / flags).

---

## 9. Decisions (locked in)

- **Facility definition:** **Both** entity type (2 = organization) **and** taxonomies that may be facility-related (identify/curate list).
- **One address per sub-org:** Yes. One sub-org = one (facility, address); different suite or line 1 = different sub-org.
- **NPI in multiple sub-orgs:** Yes — NPIs can be in multiple sub-orgs (e.g. one NPI at two locations).
- **No TIN from DOGE:** We only have **billing NPI**. Use **billing NPI** as a grouping dimension in addition to address. **Union:** address-based org/sub-org **and** billing-NPI-based member list.
- **Output:** Org id, sub-org id, NPI, TIN (when available), associated member NPIs — all of the above in the produced list.

---

## 10. Summary

| Piece | Purpose |
|-------|--------|
| Facility master list | Entity type 2 **and** facility-related taxonomies; billing/practice address, ZIP+9. |
| Address propensity matching | Strong: same mailing, same servicing, same ZIP+9. Partial: ZIP5, street, city+state. |
| Sub-org | **One address per sub-org** (suite/line can differ → different sub-org). One facility + one address + all NPIs that match. NPIs **can** be in multiple sub-orgs. |
| Org | Multiple sub-orgs rolling up by **facility NPI**. **Plus** billing-NPI-based grouping (we have no TIN): billing NPI → member NPIs. **Union** address-based and billing-NPI-based. |
| Output | Org id, sub-org id, NPI, TIN (when available), **associated member NPIs** — for both address-based and billing-NPI-based views. |
| Roster evaluation | Match given roster to this structure; flag discrepancies. |
| No roster | Still produce list of entries (org / sub-org / NPI / billing NPI / member NPIs / address / flags). |

**Next:** Identify facility-related taxonomies; then break into concrete steps and tables/views for build.
