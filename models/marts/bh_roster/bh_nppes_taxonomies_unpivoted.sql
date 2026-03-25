{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Unpivoted NPPES taxonomies (1-15) for roster servicing NPIs.
-- One row per (npi, taxonomy_code). Enables multi-taxonomy readiness checks.
-- See: NPI with A,B,C in NPPES → 3 rows; PML may have only B; we create rows for all.

with roster_npis as (
  select distinct cast(servicing_npi as string) as npi
  from {{ ref('bh_roster') }}
  where servicing_npi is not null and trim(cast(servicing_npi as string)) != ''
),
nppes as (
  select
    cast(n.npi as string) as npi,
    n.healthcare_provider_taxonomy_code_1 as code_1,
    n.healthcare_provider_taxonomy_code_2 as code_2,
    n.healthcare_provider_taxonomy_code_3 as code_3,
    n.healthcare_provider_taxonomy_code_4 as code_4,
    n.healthcare_provider_taxonomy_code_5 as code_5,
    n.healthcare_provider_taxonomy_code_6 as code_6,
    n.healthcare_provider_taxonomy_code_7 as code_7,
    n.healthcare_provider_taxonomy_code_8 as code_8,
    n.healthcare_provider_taxonomy_code_9 as code_9,
    n.healthcare_provider_taxonomy_code_10 as code_10,
    n.healthcare_provider_taxonomy_code_11 as code_11,
    n.healthcare_provider_taxonomy_code_12 as code_12,
    n.healthcare_provider_taxonomy_code_13 as code_13,
    n.healthcare_provider_taxonomy_code_14 as code_14,
    n.healthcare_provider_taxonomy_code_15 as code_15
  from {{ source('nppes_public', 'npi_raw') }} n
  inner join roster_npis r on cast(n.npi as string) = r.npi
),
unpiv as (
  select npi, 1 as taxonomy_slot, trim(cast(code_1 as string)) as taxonomy_code, true as is_primary from nppes where code_1 is not null and trim(cast(code_1 as string)) != ''
  union all select npi, 2, trim(cast(code_2 as string)), false from nppes where code_2 is not null and trim(cast(code_2 as string)) != ''
  union all select npi, 3, trim(cast(code_3 as string)), false from nppes where code_3 is not null and trim(cast(code_3 as string)) != ''
  union all select npi, 4, trim(cast(code_4 as string)), false from nppes where code_4 is not null and trim(cast(code_4 as string)) != ''
  union all select npi, 5, trim(cast(code_5 as string)), false from nppes where code_5 is not null and trim(cast(code_5 as string)) != ''
  union all select npi, 6, trim(cast(code_6 as string)), false from nppes where code_6 is not null and trim(cast(code_6 as string)) != ''
  union all select npi, 7, trim(cast(code_7 as string)), false from nppes where code_7 is not null and trim(cast(code_7 as string)) != ''
  union all select npi, 8, trim(cast(code_8 as string)), false from nppes where code_8 is not null and trim(cast(code_8 as string)) != ''
  union all select npi, 9, trim(cast(code_9 as string)), false from nppes where code_9 is not null and trim(cast(code_9 as string)) != ''
  union all select npi, 10, trim(cast(code_10 as string)), false from nppes where code_10 is not null and trim(cast(code_10 as string)) != ''
  union all select npi, 11, trim(cast(code_11 as string)), false from nppes where code_11 is not null and trim(cast(code_11 as string)) != ''
  union all select npi, 12, trim(cast(code_12 as string)), false from nppes where code_12 is not null and trim(cast(code_12 as string)) != ''
  union all select npi, 13, trim(cast(code_13 as string)), false from nppes where code_13 is not null and trim(cast(code_13 as string)) != ''
  union all select npi, 14, trim(cast(code_14 as string)), false from nppes where code_14 is not null and trim(cast(code_14 as string)) != ''
  union all select npi, 15, trim(cast(code_15 as string)), false from nppes where code_15 is not null and trim(cast(code_15 as string)) != ''
)
select npi, taxonomy_slot, taxonomy_code, is_primary
from unpiv
