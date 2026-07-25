#!/usr/bin/env sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(dirname "$script_dir")
python_command=${PYTHON:-python3}
exec "$python_command" "$root/tools/release.py" --root "$root" "$@"
