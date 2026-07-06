{{
  config(
    materialized='table',
  )
}}

-- Org Spine for Strategy
-- Grain: one row per org_slug × period_year.
-- Sources core identity, tier, size, growth, and clinician mix from
-- org_profile_v2 (financial_benchmarking). Enriches with RUCA market
-- classification from the strategy mart.

with org as (
    select
        -- Identity
        org_slug,
        org_name,
        org_state,
        org_zip5,
        org_city,
        primary_taxonomy_code,
        billing_npi_count,
        org_type,
        cmhc_tier,
        market_tier,
        size_band,
        period_year,

        -- Flags
        first_claim_year,
        is_new_entrant,
        care_focus,
        growth_trajectory,
        revenue_growth_pct,
        bene_growth_pct,
        rate_position,
        panel_efficiency,

        -- Scale
        servicing_npi_count,
        panel_size,
        total_claims,
        total_paid,

        -- Unit economics
        panel_per_clinician,
        claims_per_beneficiary,
        payment_per_claim,
        revenue_per_bene,

        -- Peer benchmarks
        peer_p50_panel_per_clin,
        peer_p50_claims_per_bene,
        peer_p50_payment_per_claim,

        -- Clinician mix
        psychiatry_count,
        counselor_count,
        social_worker_count,
        mft_count,
        psychologist_count,
        aprn_count,
        other_clinician_count,
        psychiatry_pct,
        counselor_pct
    from {{ ref('org_profile_v2') }}
),

-- Independent org classification flags from org_npi_map
-- (is_bhpf_client and is_fbha_member are NOT mutually exclusive)
org_flags as (
    select distinct
        org_slug,
        is_bhpf_client,
        is_fbha_member,
        org_type
    from {{ ref('org_npi_map') }}
),

-- Enrich with RUCA for the org's primary ZIP
ruca as (
    select zip5, ruca_category, primary_ruca, po_name
    from {{ ref('ruca_fl_zips') }}
)

select
    o.*,
    coalesce(r.ruca_category, 'unknown') as ruca_category,
    coalesce(r.primary_ruca, 'unknown')  as primary_ruca,

    -- Independent classification flags (not mutually exclusive)
    coalesce(f.is_bhpf_client, false) as is_bhpf,
    coalesce(f.is_fbha_member, false) as is_fbha,
    o.cmhc_tier in ('tier1_bhpf', 'tier2_fbha', 'tier3_lookalike') as is_cmhc,
    o.org_type = 'CMHC' as is_cmhc_taxonomy,
    o.org_type = 'FQHC' as is_fqhc,
    o.org_type = 'HOSPITAL' as is_hospital,
    o.org_type = 'SUD' as is_sud,
    o.org_type = 'RESIDENTIAL_BH' as is_residential,
    o.org_type = 'RHC' as is_rhc,
    o.org_type = 'PCP' as is_pcp,
    o.org_type in ('BH_SPECIALTY', 'COMMUNITY_BH') as is_bh_specialty

from org o
left join org_flags f on f.org_slug = o.org_slug
left join ruca r on r.zip5 = o.org_zip5
