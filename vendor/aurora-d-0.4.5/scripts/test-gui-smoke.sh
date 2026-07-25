#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$script_dir")
cd "$root"

compiler=${DC:-ldc2}
dub_command=${DUB:-dub}
renderers=${AURORA_GUI_RENDERERS:-software}
duration=${AURORA_GUI_SMOKE_SECONDS:-2}

if ! command -v timeout >/dev/null 2>&1; then
  printf '%s\n' 'The GUI smoke test requires the POSIX timeout command.' >&2
  exit 2
fi
if [ -z "${DISPLAY:-}" ]; then
  printf '%s\n' 'The GUI smoke test requires DISPLAY (a real X server or Xvfb).' >&2
  exit 2
fi

for config in notepad file-explorer desktop taskbar font-gallery; do
  "$dub_command" build --config="$config" --build=debug \
    --compiler="$compiler" --force
done

temporary=$(mktemp -d "${TMPDIR:-/tmp}/aurora-gui-smoke.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

for renderer in $renderers; do
  case "$renderer" in
    software|vulkan) ;;
    *)
      printf 'Unknown GUI smoke renderer: %s\n' "$renderer" >&2
      exit 2
      ;;
  esac
  for executable in \
    aurora-notepad \
    aurora-file-explorer \
    aurora-desktop \
    aurora-taskbar \
    aurora-font-gallery
  do
    printf 'GUI smoke: %s / %s\n' "$renderer" "$executable"
    stdout="$temporary/$renderer-$executable.stdout"
    stderr="$temporary/$renderer-$executable.stderr"
    set +e
    AURORA_RENDERER="$renderer" timeout --kill-after=2 "$duration" "./$executable" \
      >"$stdout" 2>"$stderr"
    code=$?
    set -e
    if [ "$code" -ne 124 ]; then
      printf 'Unexpected exit %s for %s / %s\n' "$code" "$renderer" \
        "$executable" >&2
      cat "$stdout" >&2
      cat "$stderr" >&2
      exit 1
    fi
    if [ -s "$stderr" ]; then
      printf 'Unexpected stderr for %s / %s:\n' "$renderer" \
        "$executable" >&2
      cat "$stderr" >&2
      exit 1
    fi
  done
done

printf '%s\n' 'GUI startup and event-loop smoke completed successfully.'
