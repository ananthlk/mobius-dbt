{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Deduplicated organization entities with org type classification.
-- Billing NPIs are grouped by (norm_org_name, org_state, org_zip5).
-- org_entity_id: stable MD5 hash of the grouping key.
--
-- Org type taxonomy:
--   Priority order ensures the most specific/structured designation wins when
--   an org has billing NPIs with mixed taxonomy codes (e.g. a CMHC that also
--   files residential claims gets classified as CMHC, not RESIDENTIAL_BH).
--
--   1  FQHC          — Federally Qualified Health Center (261QF0400X)
--   2  CMHC          — Community Mental Health Center (261QM0801X)
--   3  RHC           — Rural Health Clinic (261QR1300X)
--   4  SUD           — Substance Use Disorder specialty
--   5  RESIDENTIAL_BH— Psychiatric / BH residential treatment
--   6  COMMUNITY_BH  — Outpatient community BH & clinic/center orgs
--   7  BH_SPECIALTY  — Outpatient specialty practices (individual/group therapy)
--   8  OTHER         — Medicaid-billing orgs outside BH taxonomy scope
--
-- Market tier:
--   Count of distinct org entities in the same (state, zip5, org_type) market.
--   sparse   < 3  — likely rural / frontier / underserved
--   moderate 3–9  — suburban / mid-size market
--   dense    ≥ 10 — urban / competitive market
--
-- Regional offices: same name + different ZIP = separate entities (intentional).
-- Parent org roll-up available in the API by grouping on (norm_org_name, org_state).

with profiles as (
    select
        billing_npi,
        raw_org_name,
        norm_org_name,
        org_state,
        org_zip5,
        org_city,
        primary_taxonomy_code
    from {{ ref('billing_npi_profiles') }}
),

-- Map each billing NPI's primary taxonomy to an org_type with priority weight.
-- Lower priority number = higher specificity = wins in plurality vote.
typed as (
    select
        *,
        case primary_taxonomy_code
            -- ── FQHC ───────────────────────────────────────────────────────
            when '261QF0400X' then struct('FQHC' as org_type, 1 as priority)
            -- ── CMHC ───────────────────────────────────────────────────────
            when '261QM0801X' then struct('CMHC' as org_type, 2 as priority)
            -- ── RHC ────────────────────────────────────────────────────────
            when '261QR1300X' then struct('RHC' as org_type, 3 as priority)
            -- ── SUD ────────────────────────────────────────────────────────
            when '101YA0400X' then struct('SUD' as org_type, 4 as priority)
            when '261QR0405X' then struct('SUD' as org_type, 4 as priority)
            when '324500000X' then struct('SUD' as org_type, 4 as priority)
            when '3245S0500X' then struct('SUD' as org_type, 4 as priority)
            when '324500000X' then struct('SUD' as org_type, 4 as priority)
            -- ── RESIDENTIAL_BH ─────────────────────────────────────────────
            when '322D00000X' then struct('RESIDENTIAL_BH' as org_type, 5 as priority)
            when '323P00000X' then struct('RESIDENTIAL_BH' as org_type, 5 as priority)
            when '3244U0102X' then struct('RESIDENTIAL_BH' as org_type, 5 as priority)
            -- ── COMMUNITY_BH ───────────────────────────────────────────────
            when '251S00000X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
            when '261QC1500X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
            when '261Q00000X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
            when '261QP2300X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
            when '251B00000X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
            when '251C00000X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
            -- ── BH_SPECIALTY ───────────────────────────────────────────────
            when '101Y00000X' then struct('BH_SPECIALTY' as org_type, 7 as priority)
            when '101YM0800X' then struct('BH_SPECIALTY' as org_type, 7 as priority)
            when '103T00000X' then struct('BH_SPECIALTY' as org_type, 7 as priority)
            when '104100000X' then struct('BH_SPECIALTY' as org_type, 7 as priority)
            when '1041C0700X' then struct('BH_SPECIALTY' as org_type, 7 as priority)
            when '106H00000X' then struct('BH_SPECIALTY' as org_type, 7 as priority)
            when '2084P0800X' then struct('BH_SPECIALTY' as org_type, 7 as priority)
            when '2084P0804X' then struct('BH_SPECIALTY' as org_type, 7 as priority)
            when '363LP0808X' then struct('BH_SPECIALTY' as org_type, 7 as priority)
            when '363LF0000X' then struct('BH_SPECIALTY' as org_type, 7 as priority)
            when '363LA2200X' then struct('BH_SPECIALTY' as org_type, 7 as priority)
            else struct('OTHER' as org_type, 8 as priority)
        end as type_info
    from profiles
),

-- Within each org entity group, pick the org_type with the lowest (best) priority
-- across all billing NPIs. Ties broken alphabetically for determinism.
org_type_per_entity as (
    select
        norm_org_name, org_state, org_zip5,
        array_agg(
            struct(type_info.org_type as org_type, type_info.priority as priority)
            order by type_info.priority asc, type_info.org_type asc
            limit 1
        )[offset(0)].org_type as org_type
    from typed
    group by 1, 2, 3
),

-- Frequency-rank raw names and taxonomies within each group for canonical selection
ranked as (
    select
        norm_org_name, org_state, org_zip5,
        raw_org_name, primary_taxonomy_code, org_city,
        count(*)  as freq,
        row_number() over (
            partition by norm_org_name, org_state, org_zip5
            order by count(*) desc, raw_org_name
        ) as rn_name,
        row_number() over (
            partition by norm_org_name, org_state, org_zip5
            order by count(*) desc, primary_taxonomy_code
        ) as rn_tax
    from profiles
    group by norm_org_name, org_state, org_zip5, raw_org_name, primary_taxonomy_code, org_city
),

canonical_name as (
    select norm_org_name, org_state, org_zip5, raw_org_name as canonical_org_name
    from ranked where rn_name = 1
),

canonical_tax as (
    select norm_org_name, org_state, org_zip5, org_city, primary_taxonomy_code as canonical_taxonomy
    from ranked where rn_tax = 1
),

billing_counts as (
    select
        norm_org_name, org_state, org_zip5,
        count(distinct billing_npi) as billing_npi_count
    from profiles
    group by 1, 2, 3
),

entities as (
    select
        to_hex(md5(concat(
            coalesce(bc.norm_org_name, ''), '|',
            coalesce(bc.org_state, ''),     '|',
            coalesce(bc.org_zip5, '')
        )))                                 as org_entity_id,
        cn.canonical_org_name               as org_name,
        bc.norm_org_name,
        bc.org_state,
        bc.org_zip5,
        ct.org_city,
        ct.canonical_taxonomy               as primary_taxonomy_code,
        ot.org_type,
        bc.billing_npi_count
    from billing_counts bc
    join canonical_name cn  on bc.norm_org_name = cn.norm_org_name and bc.org_state = cn.org_state and bc.org_zip5 = cn.org_zip5
    join canonical_tax  ct  on bc.norm_org_name = ct.norm_org_name and bc.org_state = ct.org_state and bc.org_zip5 = ct.org_zip5
    join org_type_per_entity ot on bc.norm_org_name = ot.norm_org_name and bc.org_state = ot.org_state and bc.org_zip5 = ot.org_zip5
),

-- Market tier: count of distinct org entities of the same org_type in same zip5 + state
market_counts as (
    select
        org_state, org_zip5, org_type,
        count(distinct org_entity_id) as orgs_in_market
    from entities
    group by 1, 2, 3
)

select
    e.org_entity_id,
    e.org_name,
    e.norm_org_name,
    e.org_state,
    e.org_zip5,
    e.org_city,
    e.primary_taxonomy_code,
    e.org_type,
    e.billing_npi_count,
    m.orgs_in_market,
    case
        when m.orgs_in_market >= 10 then 'dense'
        when m.orgs_in_market >= 3  then 'moderate'
        else 'sparse'
    end as market_tier

from entities e
join market_counts m
    on  e.org_state = m.org_state
    and e.org_zip5  = m.org_zip5
    and e.org_type  = m.org_type
