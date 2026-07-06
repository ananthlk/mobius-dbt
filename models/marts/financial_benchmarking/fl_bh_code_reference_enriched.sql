{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- ═══════════════════════════════════════════════════════════════════════
-- FL Medicaid BH Code Reference — single source of truth
-- ═══════════════════════════════════════════════════════════════════════
-- Classification:
--   ahca_category  — AHCA service categories. PRIMARY.
--   care_stage     — 3-way roll-up (intake / high_acuity / ongoing_treatment).
--
-- Grain: one row per hcpcs_code (code-level attributes only).
-- For spending data see fl_bh_market_monthly.
--
-- Consumers: ALL downstream BH models ref() this table.
-- ═══════════════════════════════════════════════════════════════════════

select
    hcpcs_code,
    description,
    ahca_category,
    ahca_category as service_line,
    coalesce(primary_metric, 'rpb') as primary_metric,
    care_stage
from {{ ref('fl_bh_code_reference') }}
