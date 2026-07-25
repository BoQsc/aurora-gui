#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$script_dir")
cd "$root"

compiler=${DC:-ldc2}
dub_command=${DUB:-dub}
python_command=${PYTHON:-python3}
renderers=${AURORA_GUI_RENDERERS:-software}
# xwininfo must decode Aurora's UTF-8 _NET_WM_NAME rather than replacing the
# title with a locale-conversion diagnostic under the POSIX C locale.
LC_ALL=${LC_ALL:-C.UTF-8}
export LC_ALL

if [ -z "${DISPLAY:-}" ]; then
  printf '%s\n' 'The fullscreen smoke test requires DISPLAY.' >&2
  exit 2
fi
for command in xwininfo xprop "$python_command"; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'The fullscreen smoke test requires %s.\n' "$command" >&2
    exit 2
  fi
done

"$dub_command" build --config=desktop --build=debug \
  --compiler="$compiler" --force

temporary=$(mktemp -d "${TMPDIR:-/tmp}/aurora-fullscreen-smoke.XXXXXX")
child=
cleanup()
{
  if [ -n "$child" ]; then
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

find_window()
{
  attempt=0
  while [ "$attempt" -lt 80 ]; do
    window=$(xwininfo -root -tree 2>/dev/null | awk '/Aurora Desktop Environment/ { print $1; exit }')
    if [ -n "$window" ]; then
      printf '%s\n' "$window"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.05
  done
  return 1
}

wait_fullscreen_state()
{
  window=$1
  expected=$2
  attempt=0
  while [ "$attempt" -lt 80 ]; do
    if xprop -id "$window" _NET_WM_STATE 2>/dev/null | \
        grep -q '_NET_WM_STATE_FULLSCREEN'; then
      actual=1
    else
      actual=0
    fi
    if [ "$actual" = "$expected" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.05
  done
  return 1
}

for renderer in $renderers; do
  case "$renderer" in
    software|vulkan) ;;
    *)
      printf 'Unknown fullscreen smoke renderer: %s\n' "$renderer" >&2
      exit 2
      ;;
  esac

  stdout="$temporary/$renderer.stdout"
  stderr="$temporary/$renderer.stderr"
  AURORA_RENDERER="$renderer" AURORA_FULLSCREEN=0 ./aurora-desktop \
    >"$stdout" 2>"$stderr" &
  child=$!

  window=$(find_window) || {
    printf 'Could not find the desktop window for %s.\n' "$renderer" >&2
    cat "$stdout" >&2
    cat "$stderr" >&2
    exit 1
  }
  wait_fullscreen_state "$window" 0 || {
    printf 'Desktop unexpectedly started fullscreen for %s.\n' "$renderer" >&2
    exit 1
  }

  "$python_command" tools/x11_send_key.py --window "$window" F11
  wait_fullscreen_state "$window" 1 || {
    printf 'F11 did not enter fullscreen for %s.\n' "$renderer" >&2
    xprop -id "$window" _NET_WM_STATE >&2 || true
    exit 1
  }

  "$python_command" tools/x11_send_key.py --window "$window" Escape
  wait_fullscreen_state "$window" 0 || {
    printf 'Escape did not leave fullscreen for %s.\n' "$renderer" >&2
    xprop -id "$window" _NET_WM_STATE >&2 || true
    exit 1
  }

  kill "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  child=
  if [ -s "$stderr" ]; then
    printf 'Unexpected stderr during fullscreen smoke for %s:\n' "$renderer" >&2
    cat "$stderr" >&2
    exit 1
  fi
  printf 'Fullscreen smoke: %s / F11 enter / Escape leave passed.\n' "$renderer"
done

printf '%s\n' 'Fullscreen shortcut and window-manager smoke completed successfully.'
