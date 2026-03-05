# Provider Roster / Credentialing Report POC

**Product name:** Provider Roster / Credentialing — roster of providers and their credentialing/readiness status by organization and location.

This document describes the 4-step flow, config file format, definitions, and how to run the CLI and use the skill from chat.

---

## Step flow

1. **Step 1 — Locations:** For a given org name (e.g. "David Lawrence"), the system finds all distinct locations from `bh_roster` (org_npi + site address). The user can confirm all, remove some, or add manual locations. Selected locations are passed via optional `location_ids` or a `locations.json` config file.

2. **Step 2 — NPIs per location:** For each selected location, the system lists NPIs tied to that location (from `bh_roster`). The user can add or remove NPIs per location. Overrides are passed via optional `npi_overrides` or a `npi_overrides.json` config file. The reportable set is (system ∪ add) \ remove per location.

3. **Step 3 — Per-NPI and per-combo report:** For each NPI in the reportable set, the system runs the four Medicaid NPI initiative checks (from `bh_roster_readiness`): NPI in PML, valid ZIP+4, taxonomy on TML, and NPI+taxonomy+ZIP9 combo has valid Medicaid ID. Output includes per-NPI validation summary and a full per-combo list.

4. **Step 4 — Invalid combos, recommendations, missed opportunities, ghost billing:** The report highlights invalid combos (with recommendations from PML credentialing data — pml_credentialed_combos, suggested_action in bh_roster_readiness), missed opportunities (locations with no ready NPI; NPIs in PML but combo fail), and ghost billing (DOGE claims under the org’s billing NPI where servicing NPI is not in the reportable set).

---

## Config file format

### locations.json

Restrict the report to a subset of locations by listing their `location_id` values. Each location_id is a 16-character hash derived from (org_npi, site address).

**Option A — list of location_ids:**
```json
["a1b2c3d4e5f6g7h8", "b2c3d4e5f6g7h8i9"]
```

**Option B — object with location_ids key:**
```json
{
  "location_ids": ["a1b2c3d4e5f6g7h8", "b2c3d4e5f6g7h8i9"]
}
```

To discover location_ids, run the CLI once without `--locations` and inspect the `*_locations.csv` output; the `location_id` column contains the values.

### npi_overrides.json

Per-location add/remove of NPIs. Keys are `location_id`; values are objects with optional `"add"` and `"remove"` arrays of NPI strings.

```json
{
  "a1b2c3d4e5f6g7h8": {
    "add": ["1234567890"],
    "remove": ["0987654321"]
  }
}
```

Omit a key to leave that location’s system list unchanged.

---

## Definitions

- **Ghost billing:** Servicing NPIs that **bill** under the org (in DOGE) but have **weak address/roster match** (confidence_score < 40). (Previously: DOGE claims where `billing_npi` is one of the org’s org_npis but `servicing_npi` is **not** in the reportable NPI set for that org. Materialized in ghost_billing_fl. These are providers we cannot confidently tie to that location; recommend verification.

- **Missed opportunities:** (1) Locations in scope where no servicing NPI has all four checks pass (readiness_all_pass). (2) NPIs that are in PML (check_1 pass) but do not have a valid NPI+taxonomy+ZIP9 combo (check_4 fail) — fix by aligning PML service location or NPPES.

- **Invalid combo:** A (location, NPI, taxonomy, zip9) row where at least one of the four checks fails. For **Combo mismatch**, `bh_roster_readiness` includes `pml_credentialed_combos`, `suggested_action`, and **suggested_taxonomies** (data-driven: top 3-5 co-occurring taxonomies with % confidence from FL PML, e.g. "30% of providers with your taxonomy are also credentialed as LCSW").

---

## How to run the CLI

From the Mobius repo root or `mobius-dbt`:

```bash
# Required: org name. Uses BQ_PROJECT, BQ_MARTS_MEDICAID_DATASET, BQ_LANDING_MEDICAID_DATASET from env (or defaults).
uv run python mobius-dbt/scripts/generate_provider_roster_credentialing_report.py --org-name "David Lawrence"

# Optional: restrict to selected locations
uv run python mobius-dbt/scripts/generate_provider_roster_credentialing_report.py --org-name "David Lawrence" --locations locations.json

# Optional: NPI overrides per location
uv run python mobius-dbt/scripts/generate_provider_roster_credentialing_report.py --org-name "David Lawrence" --locations locations.json --npi-overrides npi_overrides.json

# Output directory (default: mobius-dbt/reports)
uv run python mobius-dbt/scripts/generate_provider_roster_credentialing_report.py --org-name "David Lawrence" --output-dir reports/
```

**Outputs:** Markdown executive summary (`*_report.md`), CSV files for locations, npis_per_location, per_npi_validation, combos, invalid_combos, ghost_billing, and optionally one XLSX with multiple sheets (if `openpyxl` is installed).

**White-paper report (LLM-enhanced):** Run with `--enhance` to generate an executive-level, white-paper-style report (narrative overview, methodology, key findings with snapshots, insights and recommendations, and sources). Set `OPENAI_API_KEY` or `GEMINI_API_KEY` / `VERTEX_PROJECT_ID`; optional flags: `--llm-provider openai|gemini`, `--llm-model gpt-4o`. The main `.md` is the LLM output; `*_raw_summary.md` holds the raw metrics.

**Prerequisites:** `bh_roster`, `taxonomy_cooccurrence_fl`, `bh_roster_readiness`, and `ghost_billing_fl` must be built (`dbt run --select bh_roster taxonomy_cooccurrence_fl bh_roster_readiness ghost_billing_fl`). Ghost billing uses `ghost_billing_fl`; landing `stg_doge` and `stg_pml` must be populated.

**If you see "BigQuery access denied (403)":** The script uses Application Default Credentials (e.g. `gcloud auth application-default login`) or `GOOGLE_APPLICATION_CREDENTIALS`. Ensure:

1. **BigQuery API** is enabled for the project: [APIs & Services → Enable BigQuery API](https://console.cloud.google.com/apis/library/bigquery.googleapis.com).
2. **IAM roles** on the project (or dataset): your user or the service account in `GOOGLE_APPLICATION_CREDENTIALS` needs **BigQuery Job User** (`roles/bigquery.jobUser`) to run queries and **BigQuery Data Viewer** (`roles/bigquery.dataViewer`) to read tables — or use **BigQuery User** (`roles/bigquery.user`) which includes both.
3. **Datasets** `BQ_MARTS_MEDICAID_DATASET` and `BQ_LANDING_MEDICAID_DATASET` must exist in `BQ_PROJECT`; create them with `scripts/create_bq_datasets.sh` or `scripts/setup_medicaid_npi_env.sh` if needed.
4. **Application Default Credentials:** Run `gcloud auth application-default login` for the account that has the above roles, or set `GOOGLE_APPLICATION_CREDENTIALS` to a service account JSON key with those roles.

---

## How to use from chat

1. **Start the Provider Roster / Credentialing API** (so the MCP tool can call it):
   ```bash
   cd mobius-skills/provider-roster-credentialing
   uv run uvicorn app.main:app --host 0.0.0.0 --port 8010
   ```
   Set env: `BQ_PROJECT`, `BQ_MARTS_MEDICAID_DATASET`, `BQ_LANDING_MEDICAID_DATASET` if needed.

2. **Point the MCP server at the API:** Set `CHAT_SKILLS_PROVIDER_ROSTER_CREDENTIALING_URL=http://localhost:8010/report` (or the deployed URL) where mobius-skills-mcp runs.

3. **Start mobius-skills-mcp** so the tool `provider_roster_credentialing_report` is available. Chat discovers it via `list_mcp_tools()`.

4. **In chat,** the user can say:
   - "Provider roster for David Lawrence"
   - "Credentialing report for Aspire"
   - "Roster report for [org name]"

   If the tool agent’s trigger phrases match, it will call the MCP tool and return the executive summary (and key counts). For the full report (CSV/Excel), the user can run the CLI or call the API directly.

---

## Skill and API

- **Skill package:** `mobius-skills/provider-roster-credentialing/`
  - `app/core.py` — report logic (get_locations, get_npis_per_location, get_readiness_and_combos, get_ghost_billing, build_full_report). No HTTP.
  - `app/report_writer.py` — LLM white-paper generator: snapshot + methodology + definitions + sources → OpenAI or Gemini → narrative report (overview, methodology, findings, insights, sources). Used by CLI `--enhance`.
  - `app/main.py` — FastAPI: `POST /report` (body: org_name, location_ids?, npi_overrides?) returns full report JSON.

- **MCP tool:** `provider_roster_credentialing_report` in `mobius-skills-mcp/app/server.py`. Calls the skill API and returns a markdown executive summary for chat.

- **Chat routing:** `mobius-chat/app/services/tool_agent.py` — trigger phrases ("provider roster", "credentialing report", "roster for") invoke the MCP tool with the org name extracted from the question.
