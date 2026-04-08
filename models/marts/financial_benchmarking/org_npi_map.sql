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

with npi_map as (
    select
        org_slug,
        org_name,
        cast(npi as string) as npi,
        coalesce(entity_type, '') as entity_type,
        coalesce(taxonomy_code, '') as taxonomy_code,
        coalesce(source, '') as source
    from {{ source('landing_org_profile', 'org_npi_map_landing') }}
    where npi is not null and trim(cast(npi as string)) != ''
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
            else struct('OTHER' as org_type, 8 as priority)
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
    case when be.entity_type_code is not null then true else false end as in_doge

from billing_enriched be
left join org_type_per_org ot on ot.org_slug = be.org_slug
left join primary_location pl on pl.org_slug = be.org_slug and pl.rn = 1
