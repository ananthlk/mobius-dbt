-- Medicaid NPI unified landing: add program_state and product to PML, TML, PPL.
-- Run once per dataset. Replace PROJECT and DATASET (e.g. mobiusos-new, landing_medicaid_npi_dev).
-- See docs/MEDICAID_NPI_UNIFIED_LANDING.md. After migration, backfill above updates existing rows to FL / medicaid.

-- 1) stg_pml: add filter columns (keep existing state column for address/B1).
ALTER TABLE `PROJECT.DATASET.stg_pml`
  ADD COLUMN IF NOT EXISTS program_state STRING,
  ADD COLUMN IF NOT EXISTS product STRING;

UPDATE `PROJECT.DATASET.stg_pml`
SET program_state = COALESCE(program_state, 'FL'), product = COALESCE(product, 'medicaid')
WHERE program_state IS NULL OR product IS NULL;

-- 2) stg_tml
ALTER TABLE `PROJECT.DATASET.stg_tml`
  ADD COLUMN IF NOT EXISTS program_state STRING,
  ADD COLUMN IF NOT EXISTS product STRING;

UPDATE `PROJECT.DATASET.stg_tml`
SET program_state = COALESCE(program_state, 'FL'), product = COALESCE(product, 'medicaid')
WHERE program_state IS NULL OR product IS NULL;

-- 3) stg_ppl
ALTER TABLE `PROJECT.DATASET.stg_ppl`
  ADD COLUMN IF NOT EXISTS program_state STRING,
  ADD COLUMN IF NOT EXISTS product STRING;

UPDATE `PROJECT.DATASET.stg_ppl`
SET program_state = COALESCE(program_state, 'FL'), product = COALESCE(product, 'medicaid')
WHERE program_state IS NULL OR product IS NULL;
