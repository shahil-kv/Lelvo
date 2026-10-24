#!/usr/bin/env bash
# Fails if a build log has compiler warnings in our own code (third-party packages are ignored).
#   Scripts/check-warnings.sh build/ios.log [more logs…]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
found=$(grep -hE "^${root}/(iOS|macOS|Shared|Packages|UITests)/[^:]+:[0-9]+:[0-9]+: (warning|error):" "$@" | sort -u || true)
if [ -n "$found" ]; then
  echo "Compiler warnings in our code:"
  echo "$found"
  exit 1
fi
echo "No compiler warnings in our code."
