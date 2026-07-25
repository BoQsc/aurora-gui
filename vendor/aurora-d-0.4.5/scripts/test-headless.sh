#!/usr/bin/env sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$script_dir")
cd "$root"
compiler=${DC:-ldc2}
dub_command=${DUB:-dub}
"$dub_command" run --config=headless-test --build=debug \
  --compiler="$compiler" --force
