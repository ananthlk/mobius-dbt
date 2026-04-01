{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Organization-level KPIs aggregated from DOGE billing NPI claims.
-- One row per org_entity × period_year.
--
-- Clinician mix:
--   Servicing NPIs are joined to NPPES npi_optimized to classify each clinician into
--   a role bucket. Counts and percentage ratios are included.
--   Buckets: psychiatry, counselor, social_worker, mft, psychologist, aprn, other.
--   These explain WHY orgs differ on payment_per_claim — a psychiatry-heavy org
--   will naturally have higher payment than a counselor-only org.

with org_billing_map as (
    select
        oe.org_entity_id,
        oe.org_name,
        oe.norm_org_name,
        oe.org_state,
        oe.org_zip5,
        oe.org_city,
        oe.primary_taxonomy_code,
        oe.org_type,
        oe.market_tier,
        oe.billing_npi_count,
        bp.billing_npi
    from {{ ref('org_entities') }} oe
    join {{ ref('billing_npi_profiles') }} bp
        on  oe.norm_org_name = bp.norm_org_name
        and oe.org_state      = bp.org_state
        and oe.org_zip5       = bp.org_zip5
),

doge_annual as (
    select
        cast(billing_npi as string)      as billing_npi,
        cast(servicing_npi as string)    as servicing_npi,
        left(period_month, 4)            as period_year,
        cast(beneficiary_count as int64) as beneficiary_count,
        cast(claim_count as int64)       as claim_count,
        cast(total_paid as float64)      as total_paid
    from {{ source('landing_medicaid_npi', 'stg_doge') }}
    where billing_npi  is not null
      and servicing_npi is not null
      and period_month  is not null
),

org_claims as (
    select
        m.org_entity_id,
        m.org_name,
        m.norm_org_name,
        m.org_state,
        m.org_zip5,
        m.org_city,
        m.primary_taxonomy_code,
        m.org_type,
        m.market_tier,
        m.billing_npi_count,
        d.period_year,
        d.servicing_npi,
        sum(d.beneficiary_count) as bene_count,
        sum(d.claim_count)       as claim_count,
        sum(d.total_paid)        as total_paid
    from org_billing_map m
    join doge_annual d on d.billing_npi = m.billing_npi
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
),

org_annual as (
    select
        org_entity_id,
        org_name,
        norm_org_name,
        org_state,
        org_zip5,
        org_city,
        primary_taxonomy_code,
        org_type,
        market_tier,
        billing_npi_count,
        period_year,
        count(distinct servicing_npi)   as servicing_npi_count,
        sum(bene_count)                 as panel_size,
        sum(claim_count)                as total_claims,
        sum(total_paid)                 as total_paid
    from org_claims
    group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
),

-- NPPES taxonomy for each distinct servicing NPI (used for clinician mix)
nppes_tax as (
    select
        cast(npi as string)                                                             as npi,
        coalesce(nullif(trim(cast(healthcare_provider_taxonomy_code_1 as string)),''),'') as taxonomy
    from {{ source('nppes_public', 'npi_optimized') }}
    where npi is not null
),

-- Distinct (org_entity_id, period_year, servicing_npi) for mix computation
org_clinicians as (
    select distinct
        org_entity_id,
        period_year,
        servicing_npi
    from org_claims
),

-- Clinician type counts per org × year
--   Psychiatry  : MD/DO psychiatrists and psychiatric NPs
--   Counselor   : licensed counselors (LPC, LMHC, addiction counselors)
--   Social_worker: LCSW / clinical social work
--   MFT         : marriage & family therapists
--   Psychologist: doctoral-level psychologists
--   APRN        : psychiatric nurse practitioners (non-MD prescribers)
--   Other       : PCPs, admin billing, unknown
clinician_mix as (
    select
        oc.org_entity_id,
        oc.period_year,
        count(distinct oc.servicing_npi)                                                as verified_clinician_count,
        countif(n.taxonomy in (
            '2084P0800X','2084P0804X','2084P0300X','2084N0400X','2084P0805X'
        ))                                                                               as psychiatry_count,
        countif(n.taxonomy in (
            '101Y00000X','101YM0800X','101YA0400X','101YS0200X','101YP2500X'
        ))                                                                               as counselor_count,
        countif(n.taxonomy in (
            '104100000X','1041C0700X','1041S0200X'
        ))                                                                               as social_worker_count,
        countif(n.taxonomy in ('106H00000X'))                                           as mft_count,
        countif(n.taxonomy in ('103T00000X','103TA0400X','103TC0700X'))                 as psychologist_count,
        countif(n.taxonomy in (
            '363LP0808X','363LA2200X','363LF0000X','363LP1700X'
        ))                                                                               as aprn_count
    from org_clinicians oc
    left join nppes_tax n on n.npi = oc.servicing_npi
    group by 1, 2
)

select
    a.org_entity_id,
    a.org_name,
    a.norm_org_name,
    a.org_state,
    a.org_zip5,
    a.org_city,
    a.primary_taxonomy_code,
    a.org_type,
    a.market_tier,
    a.billing_npi_count,
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
    end                                                  as size_band,
    safe_divide(a.total_claims, a.panel_size)            as claims_per_beneficiary,
    safe_divide(a.total_paid,   a.total_claims)          as payment_per_claim,

    -- ── Clinician mix ───────────────────────────────────────────────────────
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
    )                                  as other_clinician_count,

    -- Ratios (0–1): fraction of servicing_npi_count per type
    round(safe_divide(coalesce(m.psychiatry_count,    0), a.servicing_npi_count), 4) as psychiatry_pct,
    round(safe_divide(coalesce(m.counselor_count,     0), a.servicing_npi_count), 4) as counselor_pct,
    round(safe_divide(coalesce(m.social_worker_count, 0), a.servicing_npi_count), 4) as social_worker_pct,
    round(safe_divide(coalesce(m.mft_count,           0), a.servicing_npi_count), 4) as mft_pct,
    round(safe_divide(coalesce(m.psychologist_count,  0), a.servicing_npi_count), 4) as psychologist_pct,
    round(safe_divide(coalesce(m.aprn_count,          0), a.servicing_npi_count), 4) as aprn_pct

from org_annual a
left join clinician_mix m
    on  m.org_entity_id = a.org_entity_id
    and m.period_year   = a.period_year
where a.panel_size  > 0
  and a.total_claims > 0
