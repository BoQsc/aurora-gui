#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$script_dir")
cd "$root"

compiler=${DC:-ldc2}
dub_command=${DUB:-dub}
python_command=${PYTHON:-python3}
ucd=${AURORA_UCD_ROOT:-tools/unicode/17.0.0}
version=$(
  "$python_command" -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' \
    "$root/dub.json"
)

printf 'Aurora-D %s verification with %s\n' "$version" "$compiler"

for command in "$dub_command" "$python_command"; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command is unavailable: %s\n' "$command" >&2
    exit 2
  fi
done

if [ ! -f "$ucd/GraphemeBreakTest.txt" ] || \
   [ ! -f "$ucd/LineBreakTest.txt" ] || \
   [ ! -f "$ucd/BidiTest.txt" ] || \
   [ ! -f "$ucd/BidiCharacterTest.txt" ]; then
  printf 'Unicode 17 conformance data is incomplete at %s\n' "$ucd" >&2
  exit 2
fi

"$python_command" tools/verify_assets.py --root "$root"

# --force prevents DUB from reusing a graph produced by a different mode.
"$dub_command" test --config=library --build=unittest --compiler="$compiler" --force

for config in headless-test public-api-test text-system-test text-boundaries dpi-rendering-test compositor-test latency-test desktop-shell-test shell-visual-test; do
  printf 'Running %s\n' "$config"
  "$dub_command" run --config="$config" --build=debug --compiler="$compiler" --force
 done

printf 'Running Unicode 17 conformance corpora (optimized runner)\n'
# The four official corpora contain 882,052 cases. The runner performs explicit
# comparisons and exit-status checks, so optimization changes only throughput;
# debug unit/integration tests above retain contract and assertion coverage.
"$dub_command" run --config=unicode-conformance --build=release \
  --compiler="$compiler" --force -- "$ucd"

for config in library notepad file-explorer desktop taskbar font-gallery vulkan-smoke; do
  printf 'Building %s\n' "$config"
  "$dub_command" build --config="$config" --build=debug \
    --compiler="$compiler" --force
 done

printf 'Aurora-D %s verification completed successfully.\n' "$version"
