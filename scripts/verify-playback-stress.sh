#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiler="${DC:-ldc2}"
build="$root/build/playback-stress"
media="$build/media"
rm -rf "$build"
mkdir -p "$media"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=30" -t 2 \
  -an -c:v libx264 -preset ultrafast -g 15 -pix_fmt yuv420p \
  "$media/stress.mp4"

"$compiler" -i -d-version=AuroraHeadless \
  -I"$root/source" -I"$root/vendor/aurora-d-0.4.5/source" \
  "$root/tests/playback_stress.d" -of="$build/playback-stress" -L-ldl
"$build/playback-stress" "$media/stress.mp4"
