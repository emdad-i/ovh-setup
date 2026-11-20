#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f vars.yml ]]; then
  echo "vars.yml not found." >&2
  echo "Copy vars.example.yml to vars.yml, fill it in, and try again." >&2
  exit 1
fi

# Extra arguments are forwarded, e.g.:
#   bash scripts/local-test.sh --check --diff
exec ansible-playbook playbook.yml -e "@vars.yml" "$@"
