-- Diagnose why Aspire roster returns 300 rows. Run each query in BigQuery separately.
-- If using different project/dataset, replace mobius-os-dev and landing/mart names.

-- 1. Total Aspire rows in bh_roster (what you see)
SELECT '1. Aspire rows in bh_roster' as step, COUNT(*) as cnt
FROM `mobius-os-dev.mobius_medicaid_npi_dev.bh_roster`
WHERE lower(org_name) LIKE '%aspire%';

-- 2. Source breakdown for Aspire
SELECT '2. Aspire by source_type' as step, source_type, COUNT(*) as cnt
FROM `mobius-os-dev.mobius_medicaid_npi_dev.bh_roster`
WHERE lower(org_name) LIKE '%aspire%'
GROUP BY source_type;

-- 3. Raw DOGE: unique (billing, servicing) pairs for Aspire billing NPIs
-- Uses medicaid-provider-spending (same source as bh_roster). Adjust table if yours differs.
WITH aspire_orgs AS (
  SELECT cast(n.npi AS STRING) AS org_npi
  FROM `bigquery-public-data.nppes.npi_raw` n
  INNER JOIN `mobius-os-dev.mobius_medicaid_npi_dev.stg_bh_taxonomy_whitelist` w
    ON n.healthcare_provider_taxonomy_code_1 = w.code
  WHERE n.entity_type_code = 2
    AND (n.provider_business_practice_location_address_state_name = 'FL'
         OR n.provider_license_number_state_code_1 = 'FL')
    AND lower(coalesce(n.provider_organization_name_legal_business_name, '')) LIKE '%aspire%'
)
SELECT '3. Raw DOGE pairs (billing=Aspire)' as step,
       COUNT(DISTINCT (cast(m.BILLING_PROVIDER_NPI_NUM as string), cast(m.SERVICING_PROVIDER_NPI_NUM as string))) as cnt
FROM `mobius-os-dev.landing_medicaid_npi_dev.medicaid-provider-spending` m
INNER JOIN aspire_orgs a ON cast(m.BILLING_PROVIDER_NPI_NUM as string) = a.org_npi
WHERE cast(m.SERVICING_PROVIDER_NPI_NUM as string) != cast(m.BILLING_PROVIDER_NPI_NUM as string);

-- 4. Total rows in medicaid-provider-spending
SELECT '4. Total medicaid-provider-spending rows' as step, COUNT(*) as cnt
FROM `mobius-os-dev.landing_medicaid_npi_dev.medicaid-provider-spending`;

-- If step 3 fails: table may not exist or have different schema. Check which table bh_roster uses.
