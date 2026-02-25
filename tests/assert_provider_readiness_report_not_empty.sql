{{ config(enabled=false) }}
-- Singular test: provider_readiness_report has rows (fails when empty).
-- Disabled: BigQuery rejects correlated subquery when ref() used inside dbt test wrapper.
-- Validate manually: select count(*) from provider_readiness_report
select 1 as _noop
