#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/outputs/Usage Monitor.app"

if [[ ! -d "$APP" ]]; then
  printf 'Widget not built yet. Run: "%s/scripts/build_app.sh"\n' "$ROOT" >&2
  exit 1
fi

printf 'Showing Usage Monitor...\n'
exec /usr/bin/open "$APP" --args --show
