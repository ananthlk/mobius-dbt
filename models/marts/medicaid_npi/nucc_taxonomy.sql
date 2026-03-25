{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- National NUCC Healthcare Provider Taxonomy code set.
-- Source: landing_medicaid_npi.stg_nucc_taxonomy.
-- If table has Code/Definition (full NUCC CSV): set var nucc_use_code_definition to true (default).
-- If table has taxonomy_code/taxonomy_description (our seed): set nucc_use_code_definition to false.
select
  trim(cast({% if var('nucc_use_code_definition', true) %}`Code`{% else %}taxonomy_code{% endif %} as string)) as taxonomy_code,
  trim(cast({% if var('nucc_use_code_definition', true) %}`Definition`{% else %}taxonomy_description{% endif %} as string)) as taxonomy_description
from {{ source('landing_medicaid_npi', 'stg_nucc_taxonomy') }}
where {% if var('nucc_use_code_definition', true) %}`Code`{% else %}taxonomy_code{% endif %} is not null
  and trim(cast({% if var('nucc_use_code_definition', true) %}`Code`{% else %}taxonomy_code{% endif %} as string)) != ''
