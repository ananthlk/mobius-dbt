-- Singular test: b0_roster_list_fl has no rows with null org_id or npi (data quality).
select *
from {{ ref('b0_roster_list_fl') }}
where org_id is null or npi is null
