#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compiler="${DC:-ldc2}"
build="$root/build/export-smoke"
media="$build/media"
output="$build/output"
rm -rf "$build"
mkdir -p "$media" "$output"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=blue:size=320x180:rate=24" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 1.25 \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -c:a aac -b:a 128k -shortest "$media/base-av.mp4"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=red:size=160x90:rate=24" -t 0.8 \
  -an -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$media/overlay.mp4"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "sine=frequency=660:sample_rate=48000" -t 0.75 \
  -c:a libmp3lame -q:a 4 "$media/extra.mp3"

"$compiler" -i -I"$root/source" "$root/tests/export_smoke.d" \
  -of="$build/export-smoke"
"$build/export-smoke" "$media/base-av.mp4" "$media/overlay.mp4" \
  "$media/extra.mp3" "$output"

ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height \
  -of default=noprint_wrappers=1 "$output/composed.mp4"
ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,channels,sample_rate \
  -of default=noprint_wrappers=1 "$output/composed.mp4"
ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,channels,sample_rate \
  -of default=noprint_wrappers=1 "$output/composed.mp3"
ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,channels,sample_rate \
  -of default=noprint_wrappers=1 "$output/v1-only.mp4"
ffprobe -v error -select_streams a:0 \
  -show_entries stream=codec_name,channels,sample_rate \
  -of default=noprint_wrappers=1 "$output/v1-only.mp3"
