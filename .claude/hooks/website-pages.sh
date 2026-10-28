#!/usr/bin/env bash
# PostToolUse hook: regenerates website/changelog.html and website/privacy.html after docs/CHANGELOG.md or
# PRIVACY.md changes, because CI fails when they are out of date.
set -euo pipefail
file=$(jq -r '.tool_input.file_path // empty')
case "$file" in
  */docs/CHANGELOG.md|*/PRIVACY.md) ;;
  *) exit 0 ;;
esac
cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"
python3 Scripts/website-pages.py >&2 || { echo "Scripts/website-pages.py failed" >&2; exit 2; }
