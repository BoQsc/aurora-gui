#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiler="${DC:-ldc2}"
build="$root/build/renderer-smoke"
rm -rf "$build"
mkdir -p "$build"

"$compiler" -i \
  -I"$root/vendor/aurora-d-0.4.5/source" \
  "$root/tests/renderer_smoke.d" -of="$build/renderer-smoke"
"$build/renderer-smoke"
