#!/usr/bin/env sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$script_dir")
cd "$root"
compiler=${DC:-ldc2}
dub_command=${DUB:-dub}

for config in notepad file-explorer desktop taskbar font-gallery; do
  printf 'Building %s with %s\n' "$config" "$compiler"
  "$dub_command" build --config="$config" --build=release \
    --compiler="$compiler" --force
 done

printf '%s\n' 'Built all Aurora-D demos. Run one with:'
printf '  %s run --config=notepad --compiler=%s\n' "$dub_command" "$compiler"
