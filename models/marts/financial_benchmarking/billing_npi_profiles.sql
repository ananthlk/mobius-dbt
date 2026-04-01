{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
  )
}}

-- All distinct billing NPIs found in DOGE, enriched with NPPES name, address, and taxonomy.
-- Used as the bridge between raw DOGE billing activity and org_entities deduplication.
--
-- Name normalization (lightweight — not credentialing-grade, fit for peer grouping):
--   1. Lowercase
--   2. Strip punctuation (→ spaces)
--   3. Remove common legal suffixes (inc, llc, corp, pc, pa, etc.)
--   4. Collapse whitespace
--
-- Address normalization:
--   - State: raw NPPES state name (e.g. "FL"); used as-is for grouping
--   - ZIP: first 5 digits of postal code
--
-- NPI not in NPPES: org_name and address fields will be empty strings.
-- These billing NPIs still flow through to org_entities but land in a catch-all
-- ('', '', '') entity group — excluded from peer distributions downstream.

with billing_npis as (
    select distinct cast(billing_npi as string) as billing_npi
    from {{ source('landing_medicaid_npi', 'stg_doge') }}
    where billing_npi is not null
      and cast(billing_npi as string) != ''
),

nppes as (
    select
        cast(npi as string)                                                                     as npi,
        cast(entity_type_code as string)                                                        as entity_type_code,

        -- Org name: type 2 = legal business name; type 1 = "Last, First"
        case
            when cast(entity_type_code as string) = '2'
                then coalesce(
                    nullif(trim(cast(provider_organization_name_legal_business_name as string)), ''),
                    ''
                )
            else coalesce(
                nullif(trim(concat(
                    coalesce(cast(provider_last_name_legal_name as string), ''),
                    case
                        when cast(provider_first_name as string) is not null
                            and trim(cast(provider_first_name as string)) != ''
                        then concat(', ', cast(provider_first_name as string))
                        else ''
                    end
                )), ''),
                ''
            )
        end                                                                                     as raw_org_name,

        coalesce(
            nullif(trim(cast(provider_business_practice_location_address_state_name as string)), ''),
            ''
        )                                                                                       as org_state,

        -- ZIP+4 → 5-digit
        substr(
            regexp_replace(
                coalesce(
                    nullif(trim(cast(provider_business_practice_location_address_postal_code as string)), ''),
                    ''
                ),
                r'[^0-9]', ''
            ),
            1, 5
        )                                                                                       as org_zip5,

        coalesce(
            nullif(trim(cast(provider_business_practice_location_address_city_name as string)), ''),
            ''
        )                                                                                       as org_city,

        coalesce(
            nullif(trim(cast(healthcare_provider_taxonomy_code_1 as string)), ''),
            ''
        )                                                                                       as primary_taxonomy_code

    from {{ source('nppes_public', 'npi_raw') }}
    where npi is not null
),

profiles as (
    select
        b.billing_npi,
        coalesce(n.entity_type_code,   '')  as entity_type_code,
        coalesce(n.raw_org_name,        '')  as raw_org_name,
        coalesce(n.org_state,           '')  as org_state,
        coalesce(n.org_zip5,            '')  as org_zip5,
        coalesce(n.org_city,            '')  as org_city,
        coalesce(n.primary_taxonomy_code, '') as primary_taxonomy_code,

        -- Normalized name for deduplication grouping.
        -- We keep "health", "center", "clinic", etc. — those are meaningful in healthcare.
        -- We only strip pure legal entity suffixes.
        trim(regexp_replace(
            regexp_replace(
                regexp_replace(
                    lower(coalesce(n.raw_org_name, '')),
                    r'[^\w\s]', ' '          -- strip punctuation → spaces
                ),
                r'\b(inc|llc|ltd|corp|lp|lc|pc|pa|pllc|pcs|plc|dba|nfp|npo|npc|co)\b', ''
            ),
            r'\s+', ' '                      -- collapse whitespace
        ))                                                                                      as norm_org_name

    from billing_npis b
    left join nppes n on n.npi = b.billing_npi
)

select * from profiles
