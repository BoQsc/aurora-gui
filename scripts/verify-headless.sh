#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiler="${DC:-ldc2}"
build="$root/build/headless-smoke"
media="$build/media"
rm -rf "$build"
mkdir -p "$media"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=blue:size=320x180:rate=30" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 1.5 \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -c:a aac -b:a 128k -shortest "$media/base-av.mp4"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=red:size=160x90:rate=30" -t 1.2 \
  -an -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$media/overlay.mp4"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=523.25:sample_rate=48000" -t 1.5 \
  -c:a libmp3lame -q:a 4 "$media/audio.mp3"

"$compiler" -i -d-version=AuroraHeadless \
  -I"$root/source" -I"$root/vendor/aurora-d-0.4.5/source" \
  "$root/tests/editor_smoke.d" -of="$build/editor-smoke" -L-ldl
AURORA_RENDERER=software SDL_AUDIODRIVER=dummy "$build/editor-smoke" \
  "$media/base-av.mp4" "$media/overlay.mp4" "$media/audio.mp3"
