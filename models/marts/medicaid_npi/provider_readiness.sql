{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Provider readiness: enrollment check. One row per (npi, billing_npi).
-- Flags: in_nppes, in_pml, in_ppl, eligible_today, eligible_3mo.
-- Date logic: PML contract_effective_date, contract_end_date. Use report_date var for point-in-time.
-- PML/PPL schema: npi required; contract_effective_date, contract_end_date for PML (adjust if column names differ).

with report_date_val as (
  select parse_date('%Y-%m-%d', '{{ var("report_date", "2026-02-01") }}') as rd
),
pairs as (
  select
    billing_npi,
    servicing_npi as npi,
    sum(claim_count) as claim_count,
    sum(total_paid) as total_paid,
    sum(beneficiary_count) as beneficiary_count
  from {{ ref('billing_servicing_pairs_fl') }}
  group by 1, 2
),
fl_npis as (
  select distinct npi from {{ ref('nppes_fl') }}
),
nppes_check as (
  select npi, true as in_nppes from {{ ref('nppes_fl') }}
),
-- PML: expect npi, contract_effective_date, contract_end_date (adjust if AHCA uses different column names)
pml_check as (
  select
    cast(npi as string) as npi,
    safe.parse_date('%Y-%m-%d', cast(contract_effective_date as string)) as eff,
    safe.parse_date('%Y-%m-%d', cast(contract_end_date as string)) as end_dt
  from {{ ref('stg_pml_run') }}
  where npi is not null
),
pml_in_table as (
  select distinct npi from pml_check
),
pml_overlap_today as (
  select npi
  from pml_check
  cross join report_date_val
  where (eff is null or eff <= rd)
    and (end_dt is null or end_dt >= rd)
),
pml_overlap_3mo as (
  select npi
  from pml_check
  cross join report_date_val
  where (eff is null or eff <= date_add(rd, interval 90 day))
    and (end_dt is null or end_dt >= date_add(rd, interval 90 day))
),
pml_contract_not_started as (
  select npi from pml_check cross join report_date_val where eff is not null and eff > rd
),
pml_contract_ended as (
  select npi from pml_check cross join report_date_val where end_dt is not null and end_dt < rd
),
ppl_check as (
  select distinct cast(npi as string) as npi
  from {{ ref('stg_ppl_run') }}
  where npi is not null
),
with_flags as (
  select
    (select rd from report_date_val) as report_date,
    p.billing_npi,
    p.npi,
    (fb.npi is not null) as fl_billing_npi,
    (nc.npi is not null) as in_nppes,
    (pit.npi is not null) as in_pml,
    (pp.npi is not null) as in_ppl,
    (pns.npi is not null) as pml_contract_not_started,
    (pce.npi is not null) as pml_contract_ended,
    p.claim_count,
    p.total_paid,
    p.beneficiary_count,
    (nc.npi is not null and po.npi is not null) as eligible_today,
    (nc.npi is not null and (po3.npi is not null or pp.npi is not null)) as eligible_3mo
  from pairs p
  left join fl_npis fb on fb.npi = p.billing_npi
  left join nppes_check nc on nc.npi = p.npi
  left join pml_in_table pit on pit.npi = p.npi
  left join pml_overlap_today po on po.npi = p.npi
  left join pml_overlap_3mo po3 on po3.npi = p.npi
  left join pml_contract_not_started pns on pns.npi = p.npi
  left join pml_contract_ended pce on pce.npi = p.npi
  left join ppl_check pp on pp.npi = p.npi
)
select
  report_date,
  billing_npi,
  npi,
  fl_billing_npi,
  in_nppes,
  in_pml,
  in_ppl,
  eligible_today,
  eligible_3mo,
  case
    when not fl_billing_npi then 'not_fl_billing_npi'
    when not in_nppes then 'not_in_nppes'
    when eligible_today and eligible_3mo then 'ready'
    when eligible_today then 'pml_expires_before_3mo'
    when pml_contract_not_started then 'pml_contract_not_started'
    when pml_contract_ended then 'pml_contract_ended'
    when in_ppl then 'in_ppl_pending'
    when not in_pml and not in_ppl then 'not_in_pml_and_not_in_ppl'
    when not in_pml then 'not_in_pml'
    else 'pml_contract_mismatch'
  end as reason_today,
  case
    when not fl_billing_npi then 'not_fl_billing_npi'
    when not in_nppes then 'not_in_nppes'
    when eligible_3mo then 'ready'
    when in_ppl then 'in_ppl_pending'
    when not in_pml and not in_ppl then 'not_in_pml_and_not_in_ppl'
    when not in_pml then 'not_in_pml'
    else 'pml_expires_before_3mo'
  end as reason_3mo,
  claim_count,
  total_paid,
  beneficiary_count
from with_flags
