{{
  config(
    materialized='table',
  )
}}

-- Org Workforce Profile
-- Grain: one row per org_slug × period_month.
-- Counts and pct of each taxonomy classification in the org's active workforce.
-- An org shifting from psychiatrists to counselors is a displacement signal.

with bh_codes as (
    select hcpcs_code from {{ ref('stg_bh_codes') }}
),

fl_npis_with_taxonomy as (
    select distinct
        cast(npi as string) as npi,
        cast(healthcare_provider_taxonomy_code_1 as string) as taxonomy_code
    from {{ source('nppes_public', 'npi_raw') }}
    where npi is not null
      and provider_business_practice_location_address_state_name = 'FL'
      and healthcare_provider_taxonomy_code_1 is not null
),

org_map as (
    select billing_npi, org_slug
    from (
        select
            cast(billing_npi as string) as billing_npi,
            org_slug,
            row_number() over (partition by billing_npi order by count(*) desc) as rn
        from {{ ref('org_npi_map') }}
        group by 1, 2
    )
    where rn = 1
),

-- NUCC classification grouping for workforce categories
nucc as (
    select
        cast(taxonomy_code as string) as taxonomy_code,
        classification,
        section
    from {{ ref('nucc_taxonomy_full') }}
),

-- Active NPIs per org × month with their taxonomy
org_npi_month as (
    select distinct
        coalesce(om.org_slug, concat('npi-', cast(d.billing_npi as string))) as org_slug,
        cast(d.servicing_npi as string) as servicing_npi,
        fl.taxonomy_code,
        d.period_month
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    inner join bh_codes bh on bh.hcpcs_code = d.hcpcs_code
    inner join fl_npis_with_taxonomy fl on fl.npi = cast(d.servicing_npi as string)
    left join org_map om on om.billing_npi = cast(d.billing_npi as string)
    where d.servicing_npi is not null
      and d.billing_npi   is not null
      and d.period_month   is not null
),

-- Classify each NPI into workforce category
npi_classified as (
    select
        o.org_slug,
        o.servicing_npi,
        o.taxonomy_code,
        o.period_month,
        case
            when n.classification in ('Psychiatry & Neurology', 'Physician') and n.section = 'Individual' then 'psychiatrist'
            when n.classification = 'Counselor' then 'counselor'
            when n.classification = 'Social Worker' then 'social_worker'
            when n.classification = 'Marriage & Family Therapist' then 'mft'
            when n.classification = 'Psychologist' then 'psychologist'
            when n.classification in ('Nurse Practitioner', 'Clinical Nurse Specialist') then 'aprn'
            when n.classification = 'Physician Assistant' then 'pa'
            when n.classification = 'Registered Nurse' then 'rn'
            when n.classification like '%Substance%' or n.classification like '%Addiction%' then 'sud_specialist'
            when n.section = 'Group' then 'group_practice'
            else 'other'
        end as workforce_category
    from org_npi_month o
    left join nucc n on n.taxonomy_code = o.taxonomy_code
),

-- Count by org × month × category
org_month_counts as (
    select
        org_slug,
        period_month,
        workforce_category,
        count(distinct servicing_npi) as provider_count
    from npi_classified
    group by 1, 2, 3
),

-- Total per org × month
org_month_total as (
    select
        org_slug,
        period_month,
        sum(provider_count) as total_providers
    from org_month_counts
    group by 1, 2
)

select
    t.org_slug,
    t.period_month,
    left(t.period_month, 4) as period_year,
    t.total_providers,

    -- Counts by category
    coalesce(sum(case when c.workforce_category = 'psychiatrist' then c.provider_count end), 0) as psychiatrist_count,
    coalesce(sum(case when c.workforce_category = 'counselor' then c.provider_count end), 0)    as counselor_count,
    coalesce(sum(case when c.workforce_category = 'social_worker' then c.provider_count end), 0) as social_worker_count,
    coalesce(sum(case when c.workforce_category = 'mft' then c.provider_count end), 0)          as mft_count,
    coalesce(sum(case when c.workforce_category = 'psychologist' then c.provider_count end), 0)  as psychologist_count,
    coalesce(sum(case when c.workforce_category = 'aprn' then c.provider_count end), 0)          as aprn_count,
    coalesce(sum(case when c.workforce_category = 'pa' then c.provider_count end), 0)            as pa_count,
    coalesce(sum(case when c.workforce_category = 'rn' then c.provider_count end), 0)            as rn_count,
    coalesce(sum(case when c.workforce_category = 'sud_specialist' then c.provider_count end), 0) as sud_specialist_count,
    coalesce(sum(case when c.workforce_category = 'group_practice' then c.provider_count end), 0) as group_practice_count,
    coalesce(sum(case when c.workforce_category = 'other' then c.provider_count end), 0)         as other_count,

    -- Pct by category
    safe_divide(sum(case when c.workforce_category = 'psychiatrist' then c.provider_count end), t.total_providers) as psychiatrist_pct,
    safe_divide(sum(case when c.workforce_category = 'counselor' then c.provider_count end), t.total_providers)    as counselor_pct,
    safe_divide(sum(case when c.workforce_category = 'social_worker' then c.provider_count end), t.total_providers) as social_worker_pct,
    safe_divide(sum(case when c.workforce_category = 'mft' then c.provider_count end), t.total_providers)          as mft_pct,
    safe_divide(sum(case when c.workforce_category = 'psychologist' then c.provider_count end), t.total_providers)  as psychologist_pct,
    safe_divide(sum(case when c.workforce_category = 'aprn' then c.provider_count end), t.total_providers)          as aprn_pct,
    safe_divide(sum(case when c.workforce_category = 'sud_specialist' then c.provider_count end), t.total_providers) as sud_specialist_pct,

    -- Workforce diversity: count of distinct categories with >0 providers
    countif(c.provider_count > 0) as workforce_category_count,

    -- Dominant workforce type (pre-computed via window)
    d.dominant_workforce_type

from org_month_total t
left join org_month_counts c
    on c.org_slug = t.org_slug
    and c.period_month = t.period_month
left join (
    select org_slug, period_month, workforce_category as dominant_workforce_type
    from (
        select org_slug, period_month, workforce_category, provider_count,
            row_number() over (partition by org_slug, period_month order by provider_count desc) as rn
        from org_month_counts
    )
    where rn = 1
) d on d.org_slug = t.org_slug and d.period_month = t.period_month
group by 1, 2, 3, 4, d.dominant_workforce_type
