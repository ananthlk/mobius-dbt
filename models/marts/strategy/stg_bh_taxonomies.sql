{{
  config(
    materialized='table',
  )
}}

-- BH Taxonomy Reference
-- Empirical: FL servicing NPIs that billed at least one BH code.
-- Description priority: TML (FL-specific) → NUCC (national fallback).
-- Grain: one row per taxonomy_code.

with bh_active_taxonomies as (
    select
        n.healthcare_provider_taxonomy_code_1 as taxonomy_code,
        count(distinct d.servicing_npi) as provider_count,
        sum(cast(d.total_paid as float64)) as total_paid
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    inner join {{ ref('stg_bh_codes') }} bh on bh.hcpcs_code = d.hcpcs_code
    inner join {{ source('nppes_public', 'npi_raw') }} n
        on cast(n.npi as string) = cast(d.servicing_npi as string)
        and n.provider_business_practice_location_address_state_name = 'FL'
    where d.servicing_npi is not null
      and n.healthcare_provider_taxonomy_code_1 is not null
      and trim(cast(n.healthcare_provider_taxonomy_code_1 as string)) != ''
    group by 1
),

tml as (
    select
        trim(cast(taxonomy_code as string)) as taxonomy_code,
        taxonomy_description
    from {{ source('landing_medicaid_npi', 'stg_tml') }}
    where program_state = 'FL'
      and product = 'medicaid'
      and taxonomy_code is not null
),

nucc as (
    select
        taxonomy_code,
        display_name,
        classification,
        specialization,
        section
    from {{ ref('nucc_taxonomy_full') }}
)

select
    bt.taxonomy_code,
    coalesce(
        nullif(trim(tml.taxonomy_description), ''),
        nucc.display_name,
        'Unknown'
    ) as taxonomy_description,
    coalesce(nucc.display_name, 'Unknown') as nucc_display_name,
    coalesce(nucc.classification, 'Unknown') as nucc_classification,
    coalesce(nucc.specialization, '') as nucc_specialization,
    coalesce(nucc.section, 'Unknown') as nucc_section,
    bt.provider_count as all_time_provider_count,
    round(bt.total_paid, 2) as all_time_total_paid
from bh_active_taxonomies bt
left join tml on tml.taxonomy_code = bt.taxonomy_code
left join nucc on nucc.taxonomy_code = bt.taxonomy_code
where bt.total_paid >= 1000000
order by bt.total_paid desc
