{{
  config(
    materialized='table',
    schema=env_var('BQ_MARTS_MEDICAID_DATASET', 'mobius_medicaid_npi_dev'),
  )
}}

-- Report-ready view: provider_readiness + billing/servicing NPI details + status_flag + status_message + address issues.
-- Feeds PDF, CSV, and chat report generation. See docs/FL_MEDICAID_PROVIDER_READINESS_REPORT_MOCKUP.md.

with base as (
  select * from {{ ref('provider_readiness') }}
),
addr_validation as (
  select billing_npi, servicing_npi, issue_b1, issue_b2, issue_b3
  from {{ ref('address_validation_fl') }}
),
tax_validation as (
  select billing_npi, servicing_npi, issue_c1, issue_c2, issue_c3, issue_c4, issue_d, issue_f
  from {{ ref('taxonomy_validation_fl') }}
),
org_details as (
  select
    billing_npi,
    org_name as billing_org_name,
    address_line_1 as billing_address_line_1,
    address_line_2 as billing_address_line_2,
    city as billing_city,
    state as billing_state,
    zip as billing_zip
  from {{ ref('organizations') }}
),
servicing_nppes as (
  select
    npi,
    coalesce(
      provider_organization_name_legal_business_name,
      concat(provider_last_name_legal_name, ', ', provider_first_name)
    ) as servicing_provider_name,
    entity_type_code as servicing_entity_type,
    provider_first_line_business_practice_location_address as servicing_address_line_1,
    provider_second_line_business_practice_location_address as servicing_address_line_2,
    provider_business_practice_location_address_city_name as servicing_city,
    provider_business_practice_location_address_state_name as servicing_state,
    provider_business_practice_location_address_postal_code as servicing_zip,
    healthcare_provider_taxonomy_code_1 as servicing_primary_taxonomy
  from {{ source('nppes_public', 'npi_optimized') }}
),
status_map as (
  select 1 as ord, 'ready' as reason, 'Ready today and set for next 3 months' as status_message
  union all select 2, 'not_fl_billing_npi', 'Billing NPI not FL-based — report N/A'
  union all select 3, 'not_in_nppes', 'NPI not in NPPES — verify registration'
  union all select 4, 'not_in_pml', 'Not enrolled in FL Medicaid — complete enrollment'
  union all select 5, 'pml_contract_ended', 'PML contract expired — renew enrollment'
  union all select 6, 'pml_contract_not_started', 'PML contract not yet effective — await activation'
  union all select 7, 'pml_expires_before_3mo', 'PML contract expires within 3 months — renew enrollment'
  union all select 8, 'in_ppl_pending', 'Enrollment pending — expected ready within 3 months'
  union all select 9, 'not_in_pml_and_not_in_ppl', 'Not enrolled — submit enrollment application'
  union all select 10, 'pml_contract_mismatch', 'PML contract mismatch — review dates'
)
select
  b.report_date,
  b.billing_npi,
  b.npi as servicing_npi,
  coalesce(o.billing_org_name, 'Unknown') as billing_org_name,
  o.billing_address_line_1,
  o.billing_address_line_2,
  o.billing_city,
  o.billing_state,
  o.billing_zip,
  coalesce(s.servicing_provider_name, 'Unknown') as servicing_provider_name,
  s.servicing_entity_type,
  s.servicing_address_line_1,
  s.servicing_address_line_2,
  s.servicing_city,
  s.servicing_state,
  s.servicing_zip,
  s.servicing_primary_taxonomy,
  -- status_flag: enrollment (A) + credentialing (B1/B3/C/D/F). B2 = info only (practice vs mailing is typical).
  case
    when not b.fl_billing_npi then 'Gray'
    when not (b.eligible_today or b.eligible_3mo) then 'Red'
    when b.eligible_today and b.eligible_3mo
         and not (coalesce(av.issue_b1, false) or coalesce(av.issue_b3, false)
                  or coalesce(tv.issue_c1, false) or coalesce(tv.issue_c2, false) or coalesce(tv.issue_c3, false)
                  or coalesce(tv.issue_c4, false) or coalesce(tv.issue_d, false) or coalesce(tv.issue_f, false))
    then 'Green'
    else 'Yellow'
  end as status_flag,
  -- readiness_score 0–100: enrollment(40) + address(15, B1/B3 only) + taxonomy(30) + utilization(15). B2 info only.
  least(100,
    case when not b.fl_billing_npi then 0 when b.eligible_today and b.eligible_3mo then 40 when b.eligible_today then 30 when b.eligible_3mo then 20 else 0 end
    + case when not (coalesce(av.issue_b1, false) or coalesce(av.issue_b3, false)) then 15 else 0 end
    + case
        when not coalesce(tv.issue_c1, false) and not (coalesce(tv.issue_c2, false) or coalesce(tv.issue_c3, false) or coalesce(tv.issue_c4, false) or coalesce(tv.issue_d, false) or coalesce(tv.issue_f, false)) then 30
        when not coalesce(tv.issue_c1, false) then 20
        else 0
      end
    + case when not coalesce(tv.issue_d, false) then 15 else 0 end
  ) as readiness_score,
  coalesce(m_today.status_message, b.reason_today) as status_message_today,
  coalesce(m_3mo.status_message, b.reason_3mo) as status_message_3mo,
  b.reason_today,
  b.reason_3mo,
  b.fl_billing_npi,
  b.in_nppes,
  b.in_pml,
  b.in_ppl,
  b.eligible_today,
  b.eligible_3mo,
  b.total_paid,
  b.claim_count,
  b.beneficiary_count,
  coalesce(av.issue_b1, false) as issue_b1,
  coalesce(av.issue_b2, false) as issue_b2,
  coalesce(av.issue_b3, false) as issue_b3,
  coalesce(tv.issue_c1, false) as issue_c1,
  coalesce(tv.issue_c2, false) as issue_c2,
  coalesce(tv.issue_c3, false) as issue_c3,
  coalesce(tv.issue_c4, false) as issue_c4,
  coalesce(tv.issue_d, false) as issue_d,
  coalesce(tv.issue_f, false) as issue_f,
  not coalesce(tv.issue_c1, false) as tml_aligned
from base b
left join org_details o on o.billing_npi = b.billing_npi
left join servicing_nppes s on s.npi = b.npi
left join addr_validation av on av.billing_npi = b.billing_npi and av.servicing_npi = b.npi
left join tax_validation tv on tv.billing_npi = b.billing_npi and tv.servicing_npi = b.npi
left join status_map m_today on m_today.reason = b.reason_today
left join status_map m_3mo on m_3mo.reason = b.reason_3mo
