#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiler="${DC:-ldc2}"
build="$root/build/model-smoke"
mkdir -p "$build"

"$compiler" -i -I"$root/source" "$root/tests/model_smoke.d" \
  -of="$build/model-smoke"
"$build/model-smoke"
