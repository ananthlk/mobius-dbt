#!/usr/bin/env bash
# Install dbt-bigquery in project venv. Run from repo root: ./scripts/install_dbt.sh

set -e
cd "$(dirname "$0")/.."

if [[ ! -d .venv ]]; then
  echo "Creating .venv..."
  python3 -m venv .venv
fi

echo "Installing dbt-bigquery..."
.venv/bin/pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

echo "Done. Activate with: source .venv/bin/activate"
echo "Then run: dbt --version"
