{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Full NUCC taxonomy lookup. All codes with classification/definition for org, site, provider.
-- Uses stg_nucc_taxonomy: Code/Definition (nucc_use_code_definition=true) or taxonomy_code/taxonomy_description.

select
  trim(cast({% if var('nucc_use_code_definition', true) %}`Code`{% else %}taxonomy_code{% endif %} as string)) as taxonomy_code,
  trim(cast({% if var('nucc_use_code_definition', true) %}`Definition`{% else %}taxonomy_description{% endif %} as string)) as taxonomy_classification
from {{ source('landing_medicaid_npi', 'stg_nucc_taxonomy') }}
where {% if var('nucc_use_code_definition', true) %}`Code`{% else %}taxonomy_code{% endif %} is not null
  and trim(cast({% if var('nucc_use_code_definition', true) %}`Code`{% else %}taxonomy_code{% endif %} as string)) != ''
