{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_FINANCIAL_DATASET', 'mobius_financial_dev'),
    tags=['periodic'],
    enabled=var('run_periodic', false),
  )
}}

-- Org-level market share / leakage metric — v2.
-- Uses credentialing-deduped org identity (org_npi_map / org_slug).
-- Grain: org_slug × period_year.
--
-- Catchment = all ZIP5s where the org has servicing NPIs (from NPPES).
-- Market share = org's claims in those zips / all BH claims in those zips.
-- Leakage = 1 − market_share.
--
-- This captures the org's geographic footprint more accurately than
-- using a single primary zip, especially for multi-site orgs.
--
-- Consumers: factor scorecard, org radar overlay, financial strategy reports.

with org_base as (
    select distinct
        om.org_slug,
        om.org_name,
        om.org_type,
        om.org_primary_zip5   as org_zip5,
        om.org_primary_state  as org_state,
        om.billing_npi
    from {{ ref('org_npi_map') }} om
    where om.in_doge = true
      and om.org_primary_state = 'FL'
      and om.org_type != 'OTHER'
      and om.org_primary_zip5 is not null
      and om.org_primary_zip5 != ''
),

-- All servicing NPI → ZIP5 mapping from NPPES (FL professional only)
npi_zips as (
    select distinct
        cast(npi as string) as npi,
        substr(provider_business_practice_location_address_postal_code, 1, 5) as zip5
    from {{ source('nppes_public', 'npi_optimized') }}
    where entity_type_code = 2
      and provider_business_practice_location_address_state_name = 'FL'
      and provider_business_practice_location_address_postal_code is not null
),

-- DOGE claims at annual grain
doge_annual as (
    select
        cast(billing_npi as string)      as billing_npi,
        cast(servicing_npi as string)    as servicing_npi,
        left(period_month, 4)            as period_year,
        cast(claim_count as int64)       as claim_count,
        cast(total_paid as float64)      as total_paid,
        cast(beneficiary_count as int64) as beneficiary_count
    from {{ source('landing_medicaid_npi', 'stg_doge') }}
    where billing_npi  is not null
      and servicing_npi is not null
      and period_month  is not null
),

-- Step 1: Find all servicing NPIs per org (from DOGE billing relationships)
org_servicing_npis as (
    select distinct
        ob.org_slug,
        ob.org_type,
        ob.org_state,
        ob.org_zip5,
        da.servicing_npi
    from org_base ob
    join doge_annual da on da.billing_npi = ob.billing_npi
),

-- Step 2: Org's catchment = all zips where org has servicing NPIs
org_catchment_zips as (
    select distinct
        osn.org_slug,
        nz.zip5 as catchment_zip
    from org_servicing_npis osn
    join npi_zips nz on nz.npi = osn.servicing_npi
),

-- Step 3: All claims in each zip (from all providers)
zip_claims as (
    select
        nz.zip5,
        da.period_year,
        da.servicing_npi,
        da.billing_npi,
        da.claim_count,
        da.total_paid,
        da.beneficiary_count
    from doge_annual da
    join npi_zips nz on nz.npi = da.servicing_npi
),

-- Step 4: For each org, sum all claims in its catchment zips
catchment_totals as (
    select
        ocz.org_slug,
        zc.period_year,
        sum(zc.claim_count)              as catchment_claims,
        sum(zc.total_paid)               as catchment_paid,
        sum(zc.beneficiary_count)        as catchment_benes,
        count(distinct zc.servicing_npi) as catchment_npis
    from org_catchment_zips ocz
    join zip_claims zc on zc.zip5 = ocz.catchment_zip
    group by 1, 2
),

-- Step 5: Org's own claims in its catchment zips
-- Join via org_base to match billing_npi to org_slug
org_in_catchment as (
    select
        ocz.org_slug,
        zc.period_year,
        sum(zc.claim_count)              as org_claims,
        sum(zc.total_paid)               as org_paid,
        sum(zc.beneficiary_count)        as org_benes,
        count(distinct zc.servicing_npi) as org_npis_in_catchment
    from org_catchment_zips ocz
    join zip_claims zc
        on  zc.zip5 = ocz.catchment_zip
    join org_base ob
        on  ob.org_slug    = ocz.org_slug
        and ob.billing_npi = zc.billing_npi
    group by 1, 2
),

-- Step 6: Org metadata
org_meta as (
    select distinct org_slug, org_type, org_state, org_zip5
    from org_servicing_npis
),

-- Catchment zip count per org
catchment_size as (
    select org_slug, count(distinct catchment_zip) as catchment_zip_count
    from org_catchment_zips
    group by 1
)

select
    om.org_slug,
    om.org_zip5,
    om.org_state,
    om.org_type,
    cs.catchment_zip_count,
    oc.period_year,
    oc.org_claims,
    oc.org_paid,
    oc.org_benes,
    oc.org_npis_in_catchment,
    ct.catchment_claims,
    ct.catchment_paid,
    ct.catchment_benes,
    ct.catchment_npis,

    -- Market share
    safe_divide(oc.org_claims, ct.catchment_claims) as market_share_claims,
    safe_divide(oc.org_paid,   ct.catchment_paid)   as market_share_paid,

    -- Leakage = 1 - market_share
    1 - safe_divide(oc.org_claims, ct.catchment_claims) as leakage_claims,
    1 - safe_divide(oc.org_paid,   ct.catchment_paid)   as leakage_paid

from org_in_catchment oc
join catchment_totals ct on ct.org_slug = oc.org_slug and ct.period_year = oc.period_year
join org_meta om on om.org_slug = oc.org_slug
left join catchment_size cs on cs.org_slug = oc.org_slug
where oc.org_claims > 0
