# B6 integrated report — performance (live interaction)

B6 is a **table** (not a view) so every query reads stored data. For fast live lookups it is **partitioned** and **clustered**.

## Table design

| Setting | Value | Purpose |
|--------|--------|--------|
| **materialized** | `table` | No view execution; read from storage only |
| **partition_by** | `report_date` (DATE) | Only the latest partition is scanned for “current” report (e.g. `WHERE report_date = (SELECT MAX(report_date) FROM ...)`) |
| **cluster_by** | `org_id`, `npi`, `org_display_name`, `npi_provider_name` | Fast lookups by org id, NPI, **org name**, or **provider name** (up to 4 columns in BQ) |

So yes — it should be a table, and it is. Partitioning + clustering is what makes live interaction fast (BigQuery has no indexes).

## Why the build was timing out (and what we did)

When B6 was the only table and B0–B5 were **views**, BigQuery had to execute the full view DAG to build B6:

- **Roster** and several CTEs depended on `nppes_fl` → `bigquery-public-data.nppes.npi_optimized` (large scan, often multiple times), so the job ran for many minutes and hit the 5‑min timeout.

**All medicaid_npi marts are now tables.** In `dbt_project.yml`, `marts.medicaid_npi` has `+materialized: table`, so:

- Roots like `nppes_fl` are built once and stored; downstream models read from them instead of re-scanning NPPES.
- B6 reads from materialized B0–B5 (and other) tables, so the B6 build finishes in minutes instead of timing out.

The BigQuery job timeout in `profiles.yml` was also increased to 30 minutes so a full run can complete.

## How to query for live use

Always filter so only the latest partition and relevant clusters are read:

- **By org name:** `WHERE report_date = (SELECT MAX(report_date) FROM \`project.dataset.b6_integrated_report_fl\`) AND LOWER(org_display_name) LIKE '%aspire%'`
- **By provider name:** same but `AND LOWER(npi_provider_name) LIKE '%smith%'`
- **By org_id or npi:** `WHERE report_date = (SELECT MAX(report_date) FROM ...) AND org_id = '...'` or `AND npi = '...'`

Avoid unbounded `SELECT *` or `COUNT(*)` without `report_date` and without a filter on org_id / npi / org_display_name / npi_provider_name.

## Summary

| Situation | Cause | What to do |
|-----------|--------|------------|
| `dbt run` on B6 times out or is slow | B0–B5 were views; full DAG ran on every B6 build | All medicaid_npi marts are now tables; B6 reads from them. Timeout in profiles.yml set to 30 min. |
| Live lookup by org/provider name is slow | No clustering on names or no partition filter | Use table with `cluster_by` including `org_display_name`, `npi_provider_name` and filter by `report_date` + name/id |
| Unfiltered `COUNT(*)` is slow | Full table scan | Add `report_date = (SELECT MAX(report_date)...)` and ideally a cluster filter |

Recreate the table after config changes so partitioning and clustering apply. To build (or rebuild) the full medicaid_npi layer:

```bash
uv run dbt run --select +b6_integrated_report_fl --full-refresh
```
