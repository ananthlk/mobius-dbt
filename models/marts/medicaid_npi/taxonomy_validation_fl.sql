{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Taxonomy validation flags: C1–C4, D (taxonomy not approved), F (entity type mismatch).

with pairs as (
  select billing_npi, servicing_npi as npi
  from {{ ref('billing_servicing_pairs_fl') }}
  group by 1, 2
),
tml_codes as (
  select distinct taxonomy_code from {{ ref('fl_medicaid_taxonomy') }}
),
nppes_primary as (
  select npi, taxonomy_code as nppes_primary_taxonomy
  from {{ ref('nppes_taxonomies_unpivoted_fl') }}
  where is_primary
),
nppes_entity as (
  select
    npi,
    entity_type_code,
    coalesce(
      provider_organization_name_legal_business_name,
      concat(provider_last_name_legal_name, ', ', provider_first_name)
    ) as provider_name
  from {{ ref('nppes_fl') }}
),
-- C1: Primary taxonomy not in TML
c1_flags as (
  select
    np.npi,
    (np.nppes_primary_taxonomy is not null
     and t.taxonomy_code is null) as issue_c1
  from nppes_primary np
  left join tml_codes t on t.taxonomy_code = np.nppes_primary_taxonomy
),
-- C2 requires PML taxonomy_code. Set var use_pml_taxonomy: false when column absent.
{% if var('use_pml_taxonomy', true) %}
pml_tax as (
  select
    cast(npi as string) as npi,
    trim(cast(taxonomy_code as string)) as pml_taxonomy
  from {{ ref('stg_pml_run') }}
  where npi is not null and taxonomy_code is not null and trim(cast(taxonomy_code as string)) != ''
  qualify row_number() over (partition by cast(npi as string) order by contract_effective_date desc nulls last) = 1
),
{% else %}
pml_tax as (select cast(null as string) as npi, cast(null as string) as pml_taxonomy from (select 1) where 1=0),
{% endif %}
c2_flags as (
  select
    np.npi,
    (pt.pml_taxonomy is not null
     and np.nppes_primary_taxonomy is not null
     and np.nppes_primary_taxonomy != pt.pml_taxonomy) as issue_c2
  from nppes_primary np
  inner join pml_tax pt on pt.npi = cast(np.npi as string)
),
-- C3: Org outlier — primary taxonomy differs from mode (most common) in billing org
org_primary_counts as (
  select
    p.billing_npi,
    np.nppes_primary_taxonomy,
    count(*) as npi_count
  from pairs p
  join nppes_primary np on np.npi = p.npi
  where np.nppes_primary_taxonomy is not null
  group by 1, 2
),
org_mode_tax as (
  select billing_npi, nppes_primary_taxonomy as mode_taxonomy
  from (
    select
      billing_npi,
      nppes_primary_taxonomy,
      row_number() over (partition by billing_npi order by npi_count desc) as rn
    from org_primary_counts
  )
  where rn = 1
),
-- C4: Entity type vs name pattern. Individual (1) with org-like name (LLC, PA, Inc).
c4_flags as (
  select
    npi,
    (
      cast(entity_type_code as string) = '1'
      and (
        upper(provider_name) like '%LLC%'
        or upper(provider_name) like '% P.A.%'
        or upper(provider_name) like '% P.A '
        or upper(provider_name) like '% INC.%'
        or upper(provider_name) like '% INC '
        or upper(provider_name) like ', INC%'
        or regexp_contains(upper(provider_name), r'\bPA\b')
        or regexp_contains(upper(provider_name), r'\bINC\b')
      )
    ) as issue_c4
  from nppes_entity
),
-- D: Billed HCPCS is outlier for provider's taxonomy combo
unpiv as (
  select npi, taxonomy_code, is_primary from {{ ref('nppes_taxonomies_unpivoted_fl') }}
),
unpiv_t2 as (
  select npi, taxonomy_code as t2,
    row_number() over (partition by npi order by taxonomy_code) as rn
  from unpiv
  where not is_primary
),
npi_t1_t2 as (
  select
    p.npi,
    p.taxonomy_code as t1,
    t2.t2
  from unpiv p
  left join unpiv_t2 t2 on t2.npi = p.npi and t2.rn = 1
  where p.is_primary
),
npi_hcpcs as (
  select servicing_npi as npi, hcpcs_code
  from {{ ref('billing_servicing_pairs_fl') }}
  group by 1, 2
),
indexed as (
  select primary_taxonomy, t2, hcpcs_code, is_outlier
  from {{ ref('taxonomy_hcpcs_volume_indexed_fl') }}
  where is_outlier
),
d_flags as (
  select distinct h.npi
  from npi_hcpcs h
  join npi_t1_t2 t on t.npi = h.npi
  join indexed i
    on i.primary_taxonomy = t.t1
    and ((i.t2 is null and t.t2 is null) or (i.t2 = t.t2))
    and i.hcpcs_code = h.hcpcs_code
),
-- F: Entity type mismatch. Organization (2) with individual-like name (no LLC/Inc/PA).
f_flags as (
  select
    npi,
    (
      cast(entity_type_code as string) = '2'
      and not (
        upper(provider_name) like '%LLC%'
        or upper(provider_name) like '%INC%'
        or upper(provider_name) like '% P.A.%'
        or regexp_contains(upper(provider_name), r'\bPA\b')
        or regexp_contains(upper(provider_name), r'\bINC\b')
      )
      and regexp_contains(provider_name, r',\s*\w+$')
    ) as issue_f
  from nppes_entity
)
select
  p.billing_npi,
  p.npi as servicing_npi,
  coalesce(c1.issue_c1, false) as issue_c1,
  coalesce(c2.issue_c2, false) as issue_c2,
  (
    np.nppes_primary_taxonomy is not null
    and m.mode_taxonomy is not null
    and np.nppes_primary_taxonomy != m.mode_taxonomy
  ) as issue_c3,
  coalesce(c4.issue_c4, false) as issue_c4,
  (d.npi is not null) as issue_d,
  coalesce(f.issue_f, false) as issue_f
from pairs p
left join nppes_primary np on np.npi = p.npi
left join c1_flags c1 on c1.npi = p.npi
left join c2_flags c2 on c2.npi = p.npi
left join org_mode_tax m on m.billing_npi = p.billing_npi
left join c4_flags c4 on c4.npi = p.npi
left join d_flags d on d.npi = p.npi
left join f_flags f on f.npi = p.npi
