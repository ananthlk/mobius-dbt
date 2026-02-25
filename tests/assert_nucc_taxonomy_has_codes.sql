-- Singular test: nucc_taxonomy has rows (run after load_nucc_to_landing.py)
-- Use LEFT JOIN to avoid BigQuery correlated subquery restriction
select 1
from (select 1 as k) a
left join (select 1 as k from {{ ref('nucc_taxonomy') }} limit 1) b on a.k = b.k
where b.k is null
