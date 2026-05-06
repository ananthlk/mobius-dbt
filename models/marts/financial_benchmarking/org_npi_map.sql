{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- Bridge table: org_slug (from credentialing-deduped org_profile) × billing_npi.
--
-- Source of truth for "which billing NPIs belong to which org" is the
-- credentialing pipeline (Postgres org_profile.confirmed_npis), synced to BQ
-- landing via scripts/sync_org_profile_to_bq.py.
--
-- This model:
--   1. Joins the synced NPI map with billing_npi_profiles (DOGE + NPPES enrichment)
--   2. Derives org_type using the same priority taxonomy logic as org_entities
--   3. Computes org-level attributes (primary location, billing NPI count)
--
-- WHY this exists alongside org_entities:
--   org_entities deduplicates by (norm_org_name, state, zip5) which fragments
--   multi-site and multi-name orgs (e.g. DLC has 4 separate entities there).
--   org_npi_map uses the credentialing pipeline's confirmed_npis — a human/algo
--   validated grouping that properly consolidates parent orgs.
--
-- Grain: one row per org_slug × billing_npi.

with raw_npi_map as (
    select
        org_slug as raw_org_slug,
        org_name as raw_org_name_landing,
        cast(npi as string) as npi,
        coalesce(entity_type, '') as entity_type,
        coalesce(taxonomy_code, '') as taxonomy_code,
        coalesce(source, '') as source
    from {{ source('landing_org_profile', 'org_npi_map_landing') }}
    where npi is not null and trim(cast(npi as string)) != ''
),

-- Dedup: collapse duplicate org_slugs (e.g. "baycare-behavioral-health" and
-- "baycare-behavioral-health-inc") into a single canonical slug.
-- The canonical_slug is the preferred identity; duplicates' NPIs merge into it.
npi_map as (
    select
        coalesce(dd.canonical_slug, rm.raw_org_slug) as org_slug,
        -- For org_name, prefer the canonical org's name (first row wins)
        first_value(rm.raw_org_name_landing) over (
            partition by coalesce(dd.canonical_slug, rm.raw_org_slug)
            order by case when dd.canonical_slug is null then 0 else 1 end,
                     rm.raw_org_slug
        ) as org_name,
        rm.npi,
        rm.entity_type,
        rm.taxonomy_code,
        rm.source
    from raw_npi_map rm
    left join {{ ref('org_slug_dedup') }} dd
        on dd.duplicate_slug = rm.raw_org_slug
),

-- Enrich with DOGE billing activity (only NPIs that appear in DOGE spending data)
billing_enriched as (
    select
        nm.org_slug,
        nm.org_name,
        nm.npi                                                as billing_npi,
        nm.entity_type,
        nm.taxonomy_code                                      as discovery_taxonomy,
        nm.source                                             as discovery_source,
        bp.entity_type_code,
        bp.raw_org_name,
        bp.norm_org_name,
        bp.org_state,
        bp.org_zip5,
        bp.org_city,
        bp.primary_taxonomy_code
    from npi_map nm
    left join {{ ref('billing_npi_profiles') }} bp
        on bp.billing_npi = nm.npi
),

-- Derive org_type per org using the same priority logic as org_entities.
-- Lower priority = more specific = wins.
typed as (
    select
        org_slug,
        coalesce(primary_taxonomy_code, discovery_taxonomy) as taxonomy_for_type,
        case coalesce(primary_taxonomy_code, discovery_taxonomy)
            when '261QF0400X' then struct('FQHC' as org_type, 1 as priority)
            when '261QM0801X' then struct('CMHC' as org_type, 2 as priority)
            when '261QR1300X' then struct('RHC' as org_type, 3 as priority)
            when '101YA0400X' then struct('SUD' as org_type, 4 as priority)
            when '261QR0405X' then struct('SUD' as org_type, 4 as priority)
            when '324500000X' then struct('SUD' as org_type, 4 as priority)
            when '3245S0500X' then struct('SUD' as org_type, 4 as priority)
            when '322D00000X' then struct('RESIDENTIAL_BH' as org_type, 5 as priority)
            when '323P00000X' then struct('RESIDENTIAL_BH' as org_type, 5 as priority)
            when '3244U0102X' then struct('RESIDENTIAL_BH' as org_type, 5 as priority)
            when '251S00000X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
            when '261QC1500X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
            when '261Q00000X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
            when '261QP2300X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
            when '251B00000X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
            when '251C00000X' then struct('COMMUNITY_BH' as org_type, 6 as priority)
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
            -- Hospital systems billing BH services
            when '282N00000X' then struct('HOSPITAL' as org_type, 8 as priority)
            when '282NC0060X' then struct('HOSPITAL' as org_type, 8 as priority)
            when '283Q00000X' then struct('HOSPITAL' as org_type, 8 as priority)
            when '284300000X' then struct('HOSPITAL' as org_type, 8 as priority)
            when '282NC2000X' then struct('HOSPITAL' as org_type, 8 as priority)
            when '282NR1301X' then struct('HOSPITAL' as org_type, 8 as priority)
            -- Primary care groups billing BH services
            when '207Q00000X' then struct('PCP' as org_type, 9 as priority)
            when '207QA0505X' then struct('PCP' as org_type, 9 as priority)
            when '207R00000X' then struct('PCP' as org_type, 9 as priority)
            when '208D00000X' then struct('PCP' as org_type, 9 as priority)
            when '261QP0905X' then struct('PCP' as org_type, 9 as priority)
            when '363L00000X' then struct('PCP' as org_type, 9 as priority)
            when '363LP2300X' then struct('PCP' as org_type, 9 as priority)
            when '207V00000X' then struct('PCP' as org_type, 9 as priority)
            when '208000000X' then struct('PCP' as org_type, 9 as priority)
            else struct('OTHER' as org_type, 10 as priority)
        end as type_info
    from billing_enriched
),

org_type_per_org as (
    select
        org_slug,
        array_agg(
            struct(type_info.org_type as org_type, type_info.priority as priority)
            order by type_info.priority asc, type_info.org_type asc
            limit 1
        )[offset(0)].org_type as org_type
    from typed
    group by 1
),

-- CMHC tier from authoritative seed (org_cmhc_universe), matched via
-- direct canonical_name OR org_aliases for rebrands/legal-name variants.
-- tier1_bhpf = BHPF client, tier2_fbha = FBHA member, NULL = not on roster.
-- Orgs with NPPES taxonomy 261QM0801X but not on the roster get
-- tier3_lookalike downstream (in org_profile_v2 or consumer queries).
cmhc_seed as (
    select
        nm.org_slug,
        cu.cmhc_tier,
        cu.is_bhpf_client,
        cu.is_fbha_member
    from npi_map nm
    inner join {{ ref('org_cmhc_universe') }} cu
        on lower(trim(nm.org_name)) = lower(trim(cu.canonical_name))

    union distinct

    -- Also match via aliases (rebrands, legal name variants, acronyms)
    select
        nm.org_slug,
        cu.cmhc_tier,
        cu.is_bhpf_client,
        cu.is_fbha_member
    from npi_map nm
    inner join {{ ref('org_aliases') }} oa
        on lower(trim(nm.org_name)) = lower(trim(oa.alias_name))
    inner join {{ ref('org_cmhc_universe') }} cu
        on oa.canonical_name = cu.canonical_name
),

cmhc_per_org as (
    select
        org_slug,
        -- If an org matches multiple seed entries (shouldn't happen), take highest tier
        array_agg(
            struct(cmhc_tier, is_bhpf_client, is_fbha_member)
            order by case cmhc_tier when 'tier1_bhpf' then 1 when 'tier2_fbha' then 2 else 3 end
            limit 1
        )[offset(0)] as seed
    from cmhc_seed
    group by 1
),

-- Pick the primary location (most-frequent state+zip across billing NPIs)
primary_location as (
    select
        org_slug,
        org_state,
        org_zip5,
        org_city,
        count(*) as loc_freq,
        row_number() over (
            partition by org_slug
            order by count(*) desc, org_state, org_zip5
        ) as rn
    from billing_enriched
    where org_state is not null and org_state != ''
    group by org_slug, org_state, org_zip5, org_city
)

select
    be.org_slug,
    be.org_name,
    be.billing_npi,
    be.entity_type_code,
    be.raw_org_name,
    be.norm_org_name,
    coalesce(be.org_state, '') as org_state,
    coalesce(be.org_zip5, '')  as org_zip5,
    coalesce(be.org_city, '')  as org_city,
    coalesce(be.primary_taxonomy_code, be.discovery_taxonomy, '') as primary_taxonomy_code,
    be.discovery_source,
    coalesce(ot.org_type, 'OTHER') as org_type,
    -- Org-level primary location (for market tier / geo grouping)
    coalesce(pl.org_state, '') as org_primary_state,
    coalesce(pl.org_zip5, '')  as org_primary_zip5,
    coalesce(pl.org_city, '')  as org_primary_city,
    -- Flag: does this NPI appear in DOGE billing data?
    case when be.entity_type_code is not null then true else false end as in_doge,

    -- CMHC tier from authoritative seed (NULL = not a rostered CMHC).
    -- tier1_bhpf / tier2_fbha from seed; tier3_lookalike = NPPES CMHC not on roster.
    coalesce(
        cmhc.seed.cmhc_tier,
        case when ot.org_type = 'CMHC' then 'tier3_lookalike' else null end
    ) as cmhc_tier,
    coalesce(cmhc.seed.is_bhpf_client, false) as is_bhpf_client,
    coalesce(cmhc.seed.is_fbha_member, false) as is_fbha_member

from billing_enriched be
left join org_type_per_org ot on ot.org_slug = be.org_slug
left join primary_location pl on pl.org_slug = be.org_slug and pl.rn = 1
left join cmhc_per_org cmhc on cmhc.org_slug = be.org_slug
