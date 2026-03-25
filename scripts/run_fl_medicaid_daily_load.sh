#!/usr/bin/env bash
# FL Medicaid daily load: optional download, then cleanse+backup+load PML and PPL, then dbt run.
#
# Prerequisites:
#   - Tables exist: run create_medicaid_tables.sh once per env.
#   - Env: BQ_PROJECT, BQ_LANDING_MEDICAID_DATASET, BQ_MARTS_MEDICAID_DATASET.
#   - Optional: GCS_MEDICAID_BUCKET for PML/PPL load; FL_MEDICAID_DATA_DIR for data directory.
#
# Usage:
#   BQ_PROJECT=mobius-os-dev BQ_LANDING_MEDICAID_DATASET=landing_medicaid_npi_dev BQ_MARTS_MEDICAID_DATASET=mobius_medicaid_npi_dev ./scripts/run_fl_medicaid_daily_load.sh
#   ./scripts/run_fl_medicaid_daily_load.sh --skip-download   # use existing files in FL_MEDICAID_DATA_DIR
#   ./scripts/run_fl_medicaid_daily_load.sh --no-backup       # first-time load (no backup)
#
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${FL_MEDICAID_DATA_DIR:-$SCRIPT_DIR/../data}"
SKIP_DOWNLOAD=false
NO_BACKUP=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-download)
      SKIP_DOWNLOAD=true
      shift
      ;;
    --no-backup)
      NO_BACKUP="--no-backup"
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--skip-download] [--no-backup]" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$DATA_DIR"
cd "$SCRIPT_DIR/.."

# Emissions: one line per step so callers can show progress (e.g. chat). Prefix [EMIT] for filtering.
_emit() { echo "[EMIT] $*"; }

echo "=== FL Medicaid daily load ==="
echo "  Data dir: $DATA_DIR"
echo "  BQ_PROJECT: ${BQ_PROJECT:-not set}"
echo "  BQ_LANDING_MEDICAID_DATASET: ${BQ_LANDING_MEDICAID_DATASET:-not set}"
echo "  BQ_MARTS_MEDICAID_DATASET: ${BQ_MARTS_MEDICAID_DATASET:-not set}"
echo ""

# 1. Download (optional)
if [[ "$SKIP_DOWNLOAD" != "true" ]]; then
  _emit "Scraping PML and PPL from Florida portal..."
  if uv run python scripts/download_ahca_medicaid.py --pml --ppl -o "$DATA_DIR"; then
    _emit "Download complete; files ready for upload."
  else
    _emit "No files from portal (auth may be required). Using existing files in data dir if present."
    echo "  Use --skip-download and place prw19000.csv / prd19100.csv in $DATA_DIR, or use --pml-path/--ppl-path with download_ahca_medicaid.py."
  fi
  echo ""
fi

# 2. PML: cleanse and load
PML_SOURCE="$DATA_DIR/prw19000.csv"
if [[ -f "$PML_SOURCE" ]]; then
  _emit "Cleaning and uploading PML to GCP..."
  uv run python scripts/cleanse_and_load_pml_prw19000.py --source "$PML_SOURCE" --load $NO_BACKUP
  _emit "PML cleaned, uploaded to GCS, and loaded to BigQuery; ready for processing."
  echo ""
else
  _emit "PML: skip (no prw19000.csv in data dir)."
  echo ""
fi

# 3. PPL: cleanse and load
PPL_SOURCE="$DATA_DIR/prd19100.csv"
if [[ -f "$PPL_SOURCE" ]]; then
  _emit "Cleaning and uploading PPL to GCP..."
  uv run python scripts/cleanse_and_load_ppl_prd19100.py --source "$PPL_SOURCE" --load $NO_BACKUP
  _emit "PPL cleaned, uploaded to GCS, and loaded to BigQuery; ready for processing."
  echo ""
else
  _emit "PPL: skip (no prd19100.csv in data dir)."
  echo ""
fi

# 4. dbt run (medicaid_npi marts)
if [[ -z "$BQ_PROJECT" || -z "$BQ_LANDING_MEDICAID_DATASET" || -z "$BQ_MARTS_MEDICAID_DATASET" ]]; then
  _emit "dbt: skip (set BQ_* env vars to run)."
else
  _emit "Running dbt (marts.medicaid_npi)..."
  dbt run --select marts.medicaid_npi
  _emit "dbt run complete."
  echo ""
fi

_emit "FL Medicaid daily load finished; data ready for reports."
echo "=== Done ==="
