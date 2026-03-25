{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Co-occurring taxonomies in FL PML: for primary_taxonomy T, % of providers with T who also have cooccurring_taxonomy.
-- Used by bh_roster_readiness for suggested_action/suggested_taxonomies.
-- Stub: returns empty set until full model is built from PML/NPPES co-occurrence analysis.

select
  cast(null as string) as primary_taxonomy,
  cast(null as string) as cooccurring_taxonomy,
  cast(null as float64) as pct,
  cast(null as int64) as npi_count_both
from (select 1) where 1 = 0
