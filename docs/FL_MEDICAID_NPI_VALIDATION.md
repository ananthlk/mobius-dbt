# FL Medicaid NPI Report Validation

## Automated tests

`dbt test` runs schema and singular tests. Some assertions are disabled because BigQuery rejects correlated subqueries when dbt wraps test SQL that references models with complex joins/refs.

## Manual checks

When validating the report:

1. **Report not empty**
   ```sql
   select count(*) from `project`.`dataset`.provider_readiness_report
   ```
   Expect > 0 rows when upstream data exists.

2. **Propensity score in 0–100**
   ```sql
   select count(*) from `project`.`dataset`.provider_propensity_score_fl
   where propensity_score < 0 or propensity_score > 100
   ```
   Expect 0 rows.

## Disabled tests

- `assert_provider_readiness_report_not_empty` — enabled=false
- `assert_provider_propensity_score_range` — enabled=false (replaced by schema test concept; schema test also hits BigQuery restriction)

See `tests/assert_*.sql` for details.
