{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Organization-level KPIs using credentialing-deduped org identity (org_npi_map).
-- Replaces org_kpis which uses site-level dedup (org_entities, 571K fragments).
-- Grain: one row per org_slug × period_year.

with org_billing_map as (
    select distinct
        om.org_slug,
        om.org_name,
        om.org_type,
        om.cmhc_tier,
        om.org_primary_state  as org_state,
        om.org_primary_zip5   as org_zip5,
        om.org_primary_city   as org_city,
        om.primary_taxonomy_code,
        om.billing_npi
    from {{ ref('org_npi_map') }} om
    where om.in_doge = true
),

-- Count billing NPIs per org
org_npi_counts as (
    select org_slug, count(distinct billing_npi) as billing_npi_count
    from org_billing_map
    group by 1
),

-- Market tier: competitor density in zip5 per org_type
market_counts as (
    select
        org_primary_state as org_state,
        org_primary_zip5  as org_zip5,
        org_type,
        count(distinct org_slug) as orgs_in_market
    from {{ ref('org_npi_map') }}
    where in_doge = true
    group by 1, 2, 3
),

bh_codes as (
    select distinct
        hcpcs_code,
        ahca_category,
        care_stage as care_spectrum
    from {{ ref('fl_bh_code_reference_enriched') }}
),

doge_annual as (
    select
        cast(billing_npi as string)      as billing_npi,
        cast(servicing_npi as string)    as servicing_npi,
        left(period_month, 4)            as period_year,
        cast(beneficiary_count as int64) as beneficiary_count,
        cast(claim_count as int64)       as claim_count,
        cast(total_paid as float64)      as total_paid,
        d.hcpcs_code,
        bh.ahca_category,
        bh.care_spectrum
    from {{ source('landing_medicaid_npi', 'stg_doge') }} d
    inner join bh_codes bh on bh.hcpcs_code = d.hcpcs_code  -- BH codes only
    where d.billing_npi  is not null
      and d.servicing_npi is not null
      and d.period_month  is not null
),

org_claims as (
    select
        m.org_slug,
        m.org_name,
        m.org_state,
        m.org_zip5,
        m.org_city,
        m.primary_taxonomy_code,
        m.org_type,
        m.cmhc_tier,
        d.period_year,
        d.servicing_npi,
        d.ahca_category,
        d.care_spectrum,
        sum(d.beneficiary_count) as bene_count,
        sum(d.claim_count)       as claim_count,
        sum(d.total_paid)        as total_paid
    from org_billing_map m
    join doge_annual d on d.billing_npi = m.billing_npi
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
),

org_annual as (
    select
        org_slug,
        org_name,
        org_state,
        org_zip5,
        org_city,
        primary_taxonomy_code,
        org_type,
        cmhc_tier,
        period_year,
        count(distinct servicing_npi)   as servicing_npi_count,
        sum(bene_count)                 as panel_size,
        sum(claim_count)                as total_claims,
        sum(total_paid)                 as total_paid,
        -- Care spectrum: paid amounts by tier
        sum(case when care_spectrum = 'intake'             then total_paid else 0 end) as intake_paid,
        sum(case when care_spectrum = 'high_acuity'        then total_paid else 0 end) as high_acuity_paid,
        sum(case when care_spectrum = 'ongoing_treatment'  then total_paid else 0 end) as ongoing_paid,
        -- Care spectrum: claim counts by tier
        sum(case when care_spectrum = 'intake'             then claim_count else 0 end) as intake_claims,
        sum(case when care_spectrum = 'high_acuity'        then claim_count else 0 end) as high_acuity_claims,
        sum(case when care_spectrum = 'ongoing_treatment'  then claim_count else 0 end) as ongoing_claims,
        -- Care spectrum: bene counts by tier
        sum(case when care_spectrum = 'intake'             then bene_count else 0 end) as intake_benes,
        sum(case when care_spectrum = 'high_acuity'        then bene_count else 0 end) as high_acuity_benes,
        sum(case when care_spectrum = 'ongoing_treatment'  then bene_count else 0 end) as ongoing_benes
    from org_claims
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9
),

-- Deduplicate NPPES to one taxonomy per NPI (prevents fan-out in clinician_mix join)
nppes_tax as (
    select
        npi,
        taxonomy
    from (
        select
            cast(npi as string) as npi,
            coalesce(nullif(trim(cast(healthcare_provider_taxonomy_code_1 as string)),''),'') as taxonomy,
            row_number() over (partition by cast(npi as string) order by cast(npi as string)) as rn
        from {{ source('nppes_public', 'npi_optimized') }}
        where npi is not null
    )
    where rn = 1
),

org_clinicians as (
    select distinct org_slug, period_year, servicing_npi
    from org_claims
),

clinician_mix as (
    select
        oc.org_slug,
        oc.period_year,
        countif(n.taxonomy in ('2084P0800X','2084P0804X','2084P0300X','2084N0400X','2084P0805X')) as psychiatry_count,
        countif(n.taxonomy in ('101Y00000X','101YM0800X','101YA0400X','101YS0200X','101YP2500X')) as counselor_count,
        countif(n.taxonomy in ('104100000X','1041C0700X','1041S0200X'))                           as social_worker_count,
        countif(n.taxonomy in ('106H00000X'))                                                     as mft_count,
        countif(n.taxonomy in ('103T00000X','103TA0400X','103TC0700X'))                           as psychologist_count,
        countif(n.taxonomy in ('363LP0808X','363LA2200X','363LF0000X','363LP1700X'))              as aprn_count
    from org_clinicians oc
    left join nppes_tax n on n.npi = oc.servicing_npi
    group by 1, 2
)

select
    a.org_slug,
    a.org_name,
    a.org_state,
    a.org_zip5,
    a.org_city,
    a.primary_taxonomy_code,
    nc.billing_npi_count,
    a.org_type,
    a.cmhc_tier,
    case
        when mc.orgs_in_market < 3  then 'sparse'
        when mc.orgs_in_market < 10 then 'moderate'
        else 'dense'
    end as market_tier,
    a.period_year,
    a.servicing_npi_count,
    a.panel_size,
    a.total_claims,
    a.total_paid,
    safe_divide(a.panel_size,    a.servicing_npi_count) as panel_per_clinician,
    case
        when safe_divide(a.panel_size, a.servicing_npi_count) <  100 then 'small'
        when safe_divide(a.panel_size, a.servicing_npi_count) <  500 then 'medium'
        else 'large'
    end as size_band,
    safe_divide(a.total_claims, a.panel_size)            as claims_per_beneficiary,
    safe_divide(a.total_paid,   a.total_claims)          as payment_per_claim,

    coalesce(m.psychiatry_count,    0) as psychiatry_count,
    coalesce(m.counselor_count,     0) as counselor_count,
    coalesce(m.social_worker_count, 0) as social_worker_count,
    coalesce(m.mft_count,           0) as mft_count,
    coalesce(m.psychologist_count,  0) as psychologist_count,
    coalesce(m.aprn_count,          0) as aprn_count,
    greatest(0,
        a.servicing_npi_count
        - coalesce(m.psychiatry_count,    0)
        - coalesce(m.counselor_count,     0)
        - coalesce(m.social_worker_count, 0)
        - coalesce(m.mft_count,           0)
        - coalesce(m.psychologist_count,  0)
        - coalesce(m.aprn_count,          0)
    ) as other_clinician_count,

    round(safe_divide(coalesce(m.psychiatry_count,    0), a.servicing_npi_count), 4) as psychiatry_pct,
    round(safe_divide(coalesce(m.counselor_count,     0), a.servicing_npi_count), 4) as counselor_pct,
    round(safe_divide(coalesce(m.social_worker_count, 0), a.servicing_npi_count), 4) as social_worker_pct,
    round(safe_divide(coalesce(m.mft_count,           0), a.servicing_npi_count), 4) as mft_pct,
    round(safe_divide(coalesce(m.psychologist_count,  0), a.servicing_npi_count), 4) as psychologist_pct,
    round(safe_divide(coalesce(m.aprn_count,          0), a.servicing_npi_count), 4) as aprn_pct,

    -- Market share: org's paid as % of all BH spending in same ZIP (local catchment)
    round(safe_divide(
        a.total_paid,
        sum(a.total_paid) over (partition by a.org_zip5, a.period_year)
    ), 6) as market_share_pct,

    -- Care spectrum: paid amounts and claim/bene counts per tier
    a.intake_paid,
    a.high_acuity_paid,
    a.ongoing_paid,
    a.intake_claims,
    a.high_acuity_claims,
    a.ongoing_claims,
    a.intake_benes,
    a.high_acuity_benes,
    a.ongoing_benes,

    -- Care spectrum market share: org's tier paid as % of all tier spending in same ZIP
    round(safe_divide(
        a.intake_paid,
        sum(a.intake_paid) over (partition by a.org_zip5, a.period_year)
    ), 6) as intake_market_share,
    round(safe_divide(
        a.high_acuity_paid,
        sum(a.high_acuity_paid) over (partition by a.org_zip5, a.period_year)
    ), 6) as high_acuity_market_share,
    round(safe_divide(
        a.ongoing_paid,
        sum(a.ongoing_paid) over (partition by a.org_zip5, a.period_year)
    ), 6) as ongoing_market_share,

    -- Org's own revenue mix across the spectrum (sums to 1.0)
    round(safe_divide(a.intake_paid,       a.total_paid), 4) as intake_revenue_pct,
    round(safe_divide(a.high_acuity_paid,  a.total_paid), 4) as high_acuity_revenue_pct,
    round(safe_divide(a.ongoing_paid,      a.total_paid), 4) as ongoing_revenue_pct,

    -- Org's beneficiary mix across the spectrum (normalized to 1.0)
    round(safe_divide(a.intake_benes,       a.intake_benes + a.high_acuity_benes + a.ongoing_benes), 4) as intake_bene_pct,
    round(safe_divide(a.high_acuity_benes,  a.intake_benes + a.high_acuity_benes + a.ongoing_benes), 4) as high_acuity_bene_pct,
    round(safe_divide(a.ongoing_benes,      a.intake_benes + a.high_acuity_benes + a.ongoing_benes), 4) as ongoing_bene_pct

from org_annual a
left join clinician_mix m on m.org_slug = a.org_slug and m.period_year = a.period_year
left join org_npi_counts nc on nc.org_slug = a.org_slug
left join market_counts mc on mc.org_state = a.org_state and mc.org_zip5 = a.org_zip5 and mc.org_type = a.org_type
where a.panel_size  > 0
  and a.total_claims > 0
