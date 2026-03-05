{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}
-- Behavioral Health Master Whitelist. Cross-checked with NPPES, NUCC, and FL Medicaid (PML).
-- Expects stg_nucc_taxonomy: Code/Definition (full NUCC) or taxonomy_code/taxonomy_description (seed).
-- Use var nucc_use_code_definition: true for Code/Definition, false for taxonomy_code/taxonomy_description.
-- bh_grouping: for chatbot narratives (Psychiatric Hospital, Residential Treatment, etc.)

with nucc as (
  select
    trim(cast({% if var('nucc_use_code_definition', true) %}`Code`{% else %}taxonomy_code{% endif %} as string)) as code,
    trim(cast({% if var('nucc_use_code_definition', true) %}`Definition`{% else %}taxonomy_description{% endif %} as string)) as classification
  from {{ source('landing_medicaid_npi', 'stg_nucc_taxonomy') }}
  where {% if var('nucc_use_code_definition', true) %}`Code`{% else %}taxonomy_code{% endif %} is not null
    and trim(cast({% if var('nucc_use_code_definition', true) %}`Code`{% else %}taxonomy_code{% endif %} as string)) != ''
)
select distinct
  code as code,
  classification as classification,
  cast(null as string) as specialization,
  case
    when code like '283Q%' then 'Psychiatric Hospital'
    when code like '32%'   then 'Residential Treatment'
    when code like '261Q%' then 'Behavioral Clinic'
    when code like '10%'   then 'Counseling/Social Work'
    when code like '207P%' then 'Psychiatry/Neurology'
    else 'Mental Health Service'
  end as bh_grouping
from nucc
where classification is not null
  and (
    classification like '%Mental Health%'
    or classification like '%Psychiatry%'
    or classification like '%Psychology%'
    or classification like '%Substance Abuse%'
    or classification like '%Behavioral Health%'
    or classification in ('Counselor', 'Social Worker', 'Psychiatric Hospital', 'Residential Treatment Facility')
  )
  or code like '261Q%'
  or code like '283Q%'
  or code like '32%'
  or code like '10%'
