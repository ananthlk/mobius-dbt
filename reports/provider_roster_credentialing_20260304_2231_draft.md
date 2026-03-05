## CEO Summary

Mobius has identified $901,143.78 in annual Medicaid revenue associated with credentialing gaps across 674 providers, including $741,231.34 in high-confidence exposure. By deploying our automated Enrollment and Roster Sync workflows, Circles of Care can help protect this revenue and access opportunities to potentially unlock additional billing from 1,106 providers in state data.

---

### Mobius Executive Dashboard
![Mobius Executive Dashboard](provider_roster_credentialing_20260304_2231_executive_dashboard.png)
*This dashboard provides a high-level overview of credentialing readiness and potential revenue impact.*

---

## Executive Overview

Circles of Care manages 2,130 unique NPIs across 3,761 provider-taxonomy-location combinations in our data. Our assessment indicates that 1,297 combinations, representing 34.5% of the total, have credentialing gaps that may prevent compliant Medicaid billing. Based on historical 2024 billing run rates, Mobius estimates approximately $901,143.78 in annual Medicaid revenue associated with these credentialing gaps, including $741,231.34 in high-confidence exposure. These combinations may be at risk for claim denial or delayed reimbursement.

Addressing these issues proactively is critical to maintaining revenue streams and reducing administrative burden. Mobius's automated tools and workflows are designed to identify and resolve these credentialing deficiencies efficiently. This process ensures that providers are properly enrolled and compliant, safeguarding existing revenue and enabling access to potential billing opportunities. We are pleased to note that no ghost billing was detected in our claims data (checked DOGE claims, last 12 months), indicating strong initial roster management. Mobius continuously monitors these combinations so that credentialing gaps are detected before they impact billing, and has identified 1,106 potential missed opportunities to expand services.

## Why This Matters

*   Mobius converts complex Medicaid credentialing rules into a single operational view of provider readiness and **automatically generates** operational workflows to resolve issues.
*   Mobius surfaces the exact provider combinations that **are highly likely to block** Medicaid billing before claims are submitted. Ensuring provider readiness means protecting current revenue and preventing delays in reimbursement, directly impacting the organization's financial health and operational efficiency.

## Methodology

This report is an **outside-in** view of provider roster and credentialing readiness. We use only the data sources available to us — we do not have access to the organization's internal records or ground truth. What we show is derived from those sources; it can contain errors, timing lags, or misclassification.

**Data freshness:** Data current as of: 2026-03-04T22:31:55.478302. Sources: FL PML snapshot, roster, and claims data.

**What we use:** (1) A provider roster that links organizations to locations and servicing providers, built from state enrollment data, federal provider data (NPPES), and historical billing patterns. (2) Florida Medicaid enrollment and taxonomy lists (PML, TML, PPL). (3) Claims or expenditure data for ghost billing and run rates. All of this is external or aggregated data — not the org's own HR or credentialing system.

**What we do:** For each organization and location in scope, we list servicing providers (NPIs) tied to that location in our roster. For each of those NPIs we run four checks against Medicaid and federal data: Is the NPI enrolled in Medicaid? Does the address have a valid 9-digit ZIP+4? Is the taxonomy allowed? Does the specific combination of NPI, taxonomy, and location have a valid Medicaid ID? We then flag rows where any check fails and surface missed opportunities and ghost billing (claims under the org's billing NPI where the servicing NPI is not on our roster).

**Unit of analysis:** A "combination" is one row: a specific NPI, taxonomy, and service location (ZIP+4). One provider can have multiple combinations (e.g., different locations or specialties). Counts of "Ready" and "invalid" are at this combination level.

**Confidence in roster attribution:** Each roster row has a **confidence score** (0–100) indicating how strongly we believe that this NPI belongs at this location. It is based on factors such as billing history (DOGE), address match strength, and building density. High confidence (e.g., 70–100) means we are more sure the NPI is truly with the organization at that site; medium (40–69) or low (0–39 / missing) means the link may be inferred or weak — e.g., same building but many unrelated offices, or no recent billing. The report breaks down invalid combinations by confidence so you can distinguish "what we are confident is real" from "what might be a data artifact or something we have missed." Use this to prioritize verification: high-confidence invalid combos are more likely to be true gaps; low-confidence ones may be false positives or roster noise.

**Important limitations:** Results are not guaranteed to be correct or complete. For example, many NPIs we flag as "Not enrolled" may have enrolled since our data was updated, may no longer be with the organization, or may be misattributed in our roster. Combo mismatches can reflect data lag between the state and the org. Use this report as a starting point for operational review and verification with the organization's own data — not as a definitive audit.

## Mobius Medicaid Readiness Score: 66 / 100

Among comparable FL behavioral health organizations, the median readiness score is 68; top quartile is 82. This indicates that Circles of Care is performing near the median for credentialing readiness in the region, but there is clear opportunity to improve.

## Key Findings

Our analysis reveals several areas where credentialing processes can be optimized to protect revenue and unlock new billing opportunities. Claims associated with these combinations are actively billing — denial risk is present today. If nothing is done in 90–180 days, continued billing under invalid combos increases exposure to claim denial and delayed reimbursement.

### Summary Metrics

| Metric | Count | Percentage |
| :-------------------------------- | ----: | ---------: |
| Total NPIs | 2,130 | |
| NPIs with all checks passing | 1,456 | 68.4% |
| NPIs with at least one issue | 674 | 31.6% |
| Total Combinations | 3,761 | |
| Ready Combinations | 2,464 | 65.5% |
| Invalid Combinations | 1,297 | 34.5% |

### Revenue at Risk and Opportunity

Our analysis identified an estimated **$901,143.78** in annual Medicaid revenue associated with credentialing gaps across 674 NPIs. Additionally, Mobius identified 1,106 missed opportunities for billing. If even 20% of these 1,106 missed opportunities are activatable at similar run rates, that could represent approximately **$153,687.74** in new billing potential.

*Missed opportunities:* Locations in scope where no servicing NPI has all four checks pass in our data, or NPIs that appear in PML but do not have a matching NPI+taxonomy+ZIP9 combo in our check. Resolving alignment unlocks billing potential.

### Readiness Status Breakdown (Top Problems)

The following table details the primary reasons for invalid combinations and their estimated annual revenue impact.

| Issue Type | Invalid Combinations | % of Total Invalid | Estimated Annual Revenue Impact |
| :------------------------- | -------------------: | -----------------: | ------------------------------: |
| Combo mismatch | 698 | 53.8% | $865,748.92 |
| Invalid address | 400 | 30.8% | $18,358.18 |
| Not enrolled | 191 | 14.7% | $17,036.68 |
| Taxonomy not permitted | 8 | 0.6% | $0.00 |

*Based on 2024 DOGE billing run rate per physician by taxonomy and location; applies run rate to distinct providers with invalid combos in each taxonomy-location cell.*

### Revenue at Risk by Issue Type
![Revenue at Risk by Issue Type](provider_roster_credentialing_20260304_2231_revenue_by_status.png)
*This chart visually represents the financial impact associated with different types of credentialing gaps.*

### Invalid Combinations by Readiness Status
![Invalid Combinations by Readiness Status](provider_roster_credentialing_20260304_2231_readiness_breakdown.png)
*This chart breaks down the types of credentialing issues affecting provider combinations.*

### Confidence in Revenue at Risk

Mobius evaluates the confidence of each NPI-location attribution. High-confidence issues are those where we are most certain the NPI is associated with your organization.

| Confidence Level | Revenue Impact |
| :--------------- | -------------: |
| High | $741,231.34 |
| Medium | $159,912.44 |
| Low | $0.00 |

**Confidence Note:** 181 invalid combinations are categorized as high confidence, meaning Mobius is very confident in the attribution of the NPI to the organization at that location. An additional 1,116 invalid combinations are at medium confidence. Prioritizing resolution for high-confidence issues can yield the most immediate and verifiable impact.

### Invalid Combinations by Confidence Level
![Invalid Combinations by Confidence Level](provider_roster_credentialing_20260304_2231_confidence_breakdown.png)
*This chart categorizes invalid combinations by Mobius's confidence in the provider-location attribution.*

### Sample Invalid Combinations

Here are illustrative examples of specific invalid combinations that require attention:

| Servicing NPI | Provider Name | Readiness Status | Summary | Suggested Action | Suggested Taxonomies |
| :------------ | :------------------ | :--------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------------- | :------------------- |
| 1013091784 | BREDIKIS, AUDRIUS | Combo mismatch | NPI is enrolled in PML (Provider Master List) and has a Medicaid ID. NPPES practice address has valid 9-digit ZIP+4. Provider taxonomy is permitted in Florida Medicaid (on TML). PML has no matching ro | PML has this taxonomy at a different ZIP. Update PML service location to match NPPES, or align roster address. | |
| 1013978055 | SEILER, EARNEST | Invalid address | NPI is enrolled in PML (Provider Master List) and has a Medicaid ID. NPPES practice ZIP+4 is not 9 digits. Expect ZIP5 + 4-digit extension (e.g. 123451234). Provider taxonomy is permitted in Florida M | | |
| 1013994698 | HIBBARD, MARY FRANCES | Invalid address | NPI is enrolled in PML (Provider Master List) and has a Medicaid ID. NPPES practice ZIP+4 is not 9 digits. Expect ZIP5 + 4-digit extension (e.g. 123451234). Provider taxonomy is permitted in Florida M | | |
| 1013998970 | BADOLATO, CRAIG | Combo mismatch | NPI is enrolled in PML (Provider Master List) and has a Medicaid ID. NPPES practice address has valid 9-digit ZIP+4. Provider taxonomy is permitted in Florida Medicaid (on TML). PML has no matching ro | PML has this taxonomy at a different ZIP. Update PML service location to match NPPES, or align roster address. | |
| 1023003514 | MCCARTHY-LAVISH, MICHELE | Combo mismatch | NPI is enrolled in PML (Provider Master List) and has a Medicaid ID. NPPES practice address has valid 9-digit ZIP+4. Provider taxonomy is permitted in Florida Medicaid (on TML). PML has no matching ro | PML has a different taxonomy at this ZIP. Add roster taxonomy to PML, or use PML taxonomy on roster. | |

## Ghost Billing Summary

No ghost billing detected (checked DOGE claims, last 12 months). This is a positive indicator of strong control over billing NPIs relative to servicing NPIs, and minimizes potential compliance risks from unknown providers billing under the organization's tax ID.

## Location Summary

Mobius has identified the following primary locations for Circles of Care:

| Standardized Location (City, State, ZIP) | Source Name Variations |
| :------------------------------------- | :--------------------- |
| MELBOURNE, FL 329015305 | CIRCLES OF CARE, INC. |
| MELBOURNE, FL 329013122 | CIRCLES OF CARE, INC. |
| ROCKLEDGE, FL 329553133 | CIRCLES OF CARE, INC. |
| WEST MELBOURNE, FL 329042335 | CIRCLES OF CARE, INC. |
| PALM BAY, FL 329053114 | CIRCLES OF CARE, INC. |
| TITUSVILLE, FL 327808050 | CIRCLES OF CARE, INC. |
| MELBOURNE, FL 329347214 | CIRCLES OF CARE, INC. |

Multiple organizational name variants appear in external data for the same location; Mobius normalizes these for accurate roster reconstruction.

## Action Plan

Optimizing the provider roster and credentialing process is a critical step to secure revenue and improve operational efficiency. The following actions are prioritized by potential impact and effort required. Mobius **automatically generates** operational workflows to streamline these resolutions.

| Priority | Issue Type | Estimated Annual Revenue Impact | Effort | Resolution Action |
| :------- | :--------------------- | :----------------------------- | :----- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1 | Combo Mismatch (Taxonomy) | $865,748.92 | Medium | **Action:** Align reported taxonomies with Florida Medicaid's Provider Master List (PML). This may involve updating the organization's internal roster or initiating a request to add missing taxonomies to the PML for the specific NPI and ZIP+4. |
| P1 | Combo Mismatch (Location/ZIP+4) | (Included in above) | Medium | **Action:** Verify and correct ZIP+4 discrepancies. Ensure the 9-digit ZIP codes for service locations match those registered in the PML. Update either the internal roster or request PML updates for NPI-taxonomy-ZIP+4 combinations. |
| P2 | Invalid Address (ZIP+4) | $18,358.18 | Low | **Action:** Update provider addresses in NPPES and internal systems to include a valid 9-digit ZIP+4. This is a foundational requirement for Florida Medicaid billing. |
| P2 | Not Enrolled | $17,036.68 | High | **Action:** Initiate Florida Medicaid enrollment for providers currently billing but not appearing on the PML, or verify if these providers have since enrolled or are no longer active. |
| P3 | Missed Opportunities Activation | $153,687.74 (potential) | Medium | **Action:** Review the 1,106 identified missed opportunities. For those deemed activatable, onboard providers, update internal rosters, and complete credentialing to unlock new billing potential. |

---

**Go deeper with Mobius Chat:** Use our chat feature to develop tailored recommendations and exportable files for each opportunity. Ask for provider-specific action lists, location-by-location breakdowns, or ready-to-upload CSVs for your credentialing workflow.

---

## Downloadable Files and Data Dictionary

The following files accompany this report for operational use, providing detailed data for each finding:

| File | Column | Description |
| :----------------------- | :------------------ | :-------------------------------------------------------------------------- |
| `locations.csv` | `zip9` | Standardized 9-digit ZIP code for the location. |
| | `org_name` | Normalized organizational name associated with the location. |
| `npis_per_location.csv` | `servicing_npi` | National Provider Identifier of the servicing provider. |
| | `location_id` | Unique identifier for the location. |
| `per_npi_validation.csv` | `servicing_npi` | National Provider Identifier of the servicing provider. |
| | `provider_taxonomy_code` | Code representing the provider's specialty. |
| | `readiness_status` | Current credentialing status (e.g., Ready, Not enrolled, Combo mismatch). |
| | `pml_credentialed_combos` | Related credentialed combinations found in PML. |
| | `suggested_action` | Recommended action to resolve the credentialing gap. |
| | `suggested_taxonomies` | Alternative taxonomies that could be used. |
| `combos.csv` | `servicing_npi` | National Provider Identifier. |
| | `provider_taxonomy_code` | Provider's taxonomy code. |
| | `readiness_status` | Current readiness status for the combination. |
| `invalid_combos.csv` | `servicing_npi` | National Provider Identifier for invalid combo. |
| | `total_paid` | Total amount paid for claims associated with this combo (historical). |
| | `confidence_score` | Mobius confidence score for the NPI-location attribution. |
| `ghost_billing.csv` | `servicing_npi` | National Provider Identifier for ghost billing (if any). |
| | `claim_count` | Number of claims for ghost billing. |
| `missed_opportunities.csv` | `servicing_npi` | NPI identified as a missed opportunity. |
| | `total_paid` | Estimated potential billing amount for this NPI. |
| `metrics.json` | `metrics` | JSON file containing all key performance indicators. |

## Appendix

### Detailed Methodology Steps

This report is based on a comprehensive, outside-in analysis:

1.  **Roster Ingestion and Reconstruction:** We start by ingesting a provided roster or reconstructing one using state enrollment data, federal NPPES records, and historical billing patterns. This process links organizations to their locations and the servicing providers (NPIs) associated with them.
2.  **Combination Definition:** For each provider (NPI) at each identified location, we create unique "combinations" of (NPI x Taxonomy x ZIP+4). A single provider may have multiple combinations if they work at different locations or offer different specialties.
3.  **Four-Point Medicaid Readiness Check:** For each combination, Mobius performs the following checks against Florida Medicaid and federal data sources:
    *   **NPI Enrollment:** Is the NPI present on the Florida Provider Master List (PML) with an active Medicaid ID?
    *   **ZIP+4 Validation:** Does the NPPES practice address have a valid 9-digit ZIP+4? Florida Medicaid requires this level of precision for service location enrollment.
    *   **Taxonomy Permitted:** Is the provider's taxonomy code (specialty) listed on Florida Medicaid's Taxonomy Master List (TML) or Pending Provider List (PPL)?
    *   **Combo Medicaid ID:** Does the specific (NPI x Taxonomy x ZIP+4) combination have a valid Medicaid ID in the PML? This ensures that the provider is enrolled for that specific service at that specific location.
4.  **Issue Flagging and Categorization:** Any combination failing one or more of these checks is flagged as "invalid" and categorized by the specific type of failure (e.g., "Not enrolled," "Invalid address," "Combo mismatch," "Taxonomy not permitted").
5.  **Confidence Scoring:** Each provider's attribution to an organization and location is assigned a confidence score (0-100) based on multiple factors such as claims history (DOGE), address matching strength, and building density. This helps distinguish between strong associations and inferred or weaker links.
6.  **Revenue Impact Estimation:** For invalid combinations, Mobius estimates potential revenue at risk by applying historical billing run rates (based on DOGE claims data) per physician, taxonomy, and location. This provides a quantifiable financial impact for each issue.
7.  **Missed Opportunities Identification:** We identify "missed opportunities" as providers who appear in state data (e.g., PML) but are not fully utilized or credentialed at any of the organization's locations in our roster, or where a location has no fully ready providers.
8.  **Ghost Billing Detection:** Mobius analyzes claims data to identify "ghost billing" – instances where a servicing NPI bills under the organization's billing NPI but cannot be confidently linked to the organization's roster or a specific location (e.g., confidence < 40).
9.  **Action Plan Generation:** Based on the identified gaps, Mobius automatically generates prioritized action plans with concrete resolution steps, enabling efficient operational remediation.

### Glossary

*   **PML:** Provider Master List – Florida Medicaid's official list of enrolled providers and their associated Medicaid IDs.
*   **TML/PPL:** Taxonomy Master List / Pending Provider List – Florida Medicaid's lists of approved taxonomy codes for providers.
*   **ZIP+4 / ZIP9:** A 9-digit ZIP code (e.g., 12345-6789) representing a precise service location, as required by Florida Medicaid for credentialing.
*   **Combination:** The fundamental unit of analysis: a unique pairing of a Servicing NPI, a Taxonomy, and a ZIP+4 service location.
*   **Ghost billing:** Servicing NPIs that bill under the organization's billing NPI but have weak address or roster matching (confidence < 40), indicating a potential roster gap or unknown provider association.
*   **Missed opportunities:** Providers or locations with potential for Medicaid billing based on state data, but not fully credentialed or utilized within the organization's current roster.
*   **Invalid combo:** A unique (Servicing NPI x Taxonomy x ZIP+4) combination where our checks against available data indicate at least one failure in Florida Medicaid's credentialing requirements.
*   **Ready:** A combination where all four Mobius checks pass, indicating the provider is credentialing-ready at that location/taxonomy/address according to our data.

## Sources

*   Florida Agency for Health Care Administration (AHCA) Medicaid Portal: [ahca.myflorida.com/medicaid](https://ahca.myflorida.com/medicaid/)
*   Florida Medicaid Provider Enrollment Information: [https://ahca.myflorida.com/medicaid/medicaid-policy-quality-and-operations/medicaid-operations/recipient-and-provider-assistance/provider-services](https://ahca.myflorida.com/medicaid/medicaid-policy-quality-and-operations/medicaid-operations/recipient-and-provider-assistance/provider-services)
*   Florida Medicaid Rules and Fee Schedules, Rule 59G-4.002, Provider Reimbursement Schedules and Billing Codes: [https://ahca.myflorida.com/medicaid/rules/rule-59g-4.002-provider-reimbursement-schedules-and-billing-codes](https://ahca.myflorida.com/medicaid/rules/rule-59g-4.002-provider-reimbursement-schedules-and-billing-codes)
*   Florida Medicaid State Plan: [https://ahca.myflorida.com/medicaid/medicaid-state-plan-under-title-xix-of-the-social-security-act-medical-assistance-program](https://ahca.myflorida.com/medicaid/medicaid-state-plan-under-title-xix-of-the-social-security-act-medical-assistance-program)
*   Florida Medicaid Policy, Quality, and Operations: [https://ahca.myflorida.com/medicaid/medicaid-policy-quality-and-operations](https://ahca.myflorida.com/medicaid/medicaid-policy-quality-and-operations)
*   Florida Medicaid Administrative Rules: [https://ahca.myflorida.com/medicaid/rules](https://ahca.myflorida.com/medicaid/rules)
*   Florida Medicaid Management Information System (FMMIS) Provider Portal: [portal.flmmis.com](http://portal.flmmis.com/)