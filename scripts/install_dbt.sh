#!/usr/bin/env bash
# NOTE: dbt is now installed in the shared venv at $MOBIUS_ROOT/.venv
# This script is kept for reference. Use the shared venv instead.

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOBIUS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV="$MOBIUS_ROOT/.venv"

if [[ ! -d "$VENV" ]]; then
  echo "Shared venv not found. Create it from workspace root:"
  echo "  cd $MOBIUS_ROOT && python3.11 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
  exit 1
fi

echo "dbt is installed in shared venv: $VENV"
echo ""
echo "Usage:"
echo "  source $VENV/bin/activate"
echo "  cd $SCRIPT_DIR/.."
echo "  dbt --version"
echo "  dbt debug"
echo "  dbt run --target dev"
