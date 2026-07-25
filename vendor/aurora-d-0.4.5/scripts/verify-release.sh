#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$script_dir")
cd "$root"

compiler=${DC:-ldc2}
verify_vulkan=${AURORA_VERIFY_VULKAN:-0}
verify_gui=${AURORA_VERIFY_GUI:-0}
skip_base_verify=${AURORA_SKIP_BASE_VERIFY:-0}
cross_targets=${AURORA_CROSS_TARGETS:-"x86_64-pc-windows-msvc x86_64-apple-darwin arm64-apple-darwin"}

if [ "$skip_base_verify" = 1 ]; then
  printf '%s\n' 'Base verification explicitly skipped; running release-only gates.'
else
  ./scripts/verify.sh
fi

compiler_path=$(command -v "$compiler" 2>/dev/null || true)
if [ -z "$compiler_path" ]; then
  printf 'Compiler is unavailable for release checks: %s\n' "$compiler" >&2
  exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/aurora-release-check.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/host" "$work/cross"

printf '%s\n' 'Compiling host graphs with warnings treated as errors'
for source in \
  source/aurora/package.d \
  demos/notepad.d \
  demos/file_explorer.d \
  demos/desktop_environment.d \
  demos/taskbar.d \
  demos/font_gallery.d \
  tests/vulkan_smoke.d
do
  name=$(basename "$source" .d)
  "$compiler_path" -w -Isource -i -c "$source" \
    -of="$work/host/$name.o"
done

for source in \
  tests/headless.d \
  tests/public_api.d \
  tests/text_system.d \
  tests/text_boundaries.d \
  tests/dpi_rendering.d \
  tests/compositor.d \
  tests/latency.d \
  tests/desktop_shell.d \
  tests/unicode_conformance.d
do
  name=$(basename "$source" .d)
  "$compiler_path" -w --d-version=AuroraHeadless -Isource -i -c "$source" \
    -of="$work/host/$name.o"
done

if "$compiler_path" --version | grep -q '^LDC'; then
  printf '%s\n' 'Cross-compiling complete native application graphs with LDC'
  for target in $cross_targets
  do
    target_dir="$work/cross/$target"
    mkdir -p "$target_dir"
    for source in \
      source/aurora/package.d \
      demos/notepad.d \
      demos/file_explorer.d \
      demos/desktop_environment.d \
      demos/taskbar.d \
      demos/font_gallery.d \
      tests/vulkan_smoke.d
    do
      name=$(basename "$source" .d)
      "$compiler_path" -w --mtriple="$target" -Isource -i -c "$source" \
        -of="$target_dir/$name.o"
    done
  done
else
  printf 'Skipping cross-target code generation: %s is not LDC.\n' "$compiler"
fi

if [ "$verify_vulkan" = 1 ]; then
  printf '%s\n' 'Running required-Vulkan smoke test'
  ./scripts/test-vulkan.sh
else
  printf '%s\n' 'Vulkan runtime smoke not requested (set AURORA_VERIFY_VULKAN=1).'
fi

if [ "$verify_gui" = 1 ]; then
  printf '%s\n' 'Running GUI startup and event-loop smoke'
  ./scripts/test-gui-smoke.sh
  printf '%s\n' 'Running fullscreen shortcut and window-manager smoke'
  ./scripts/test-fullscreen.sh
else
  printf '%s\n' 'GUI runtime smoke not requested (set AURORA_VERIFY_GUI=1).'
fi

printf '%s\n' 'Release verification completed successfully.'
