#!/usr/bin/env bash
# Build a MINIMAL SHARED FFmpeg (libavcodec/format/util/swscale DLLs) for
# Windows x64, containing only the DECODERS/DEMUXERS Aurora Cut needs for the
# optional in-process scrub decoder (aurora-cut/source/auroracut/libavdecode.d).
#
# This is deliberately NOT the full ffmpeg.exe build and NOT a general-purpose
# FFmpeg: no encoders, no filters, no avdevice, no avfilter, no CLI. The point is
# a small download that powers instant frame-accurate scrub. FFmpeg's full
# shared build (BtbN gpl-shared) is ~120 MB because avcodec enables everything;
# this keeps roughly the same decode surface as the static minimal ffmpeg.exe but
# as shared libraries.
#
# Toolchain mirrors scripts/build-minimal-ffmpeg-win64.sh (which successfully
# builds libdav1d) so the pthread-based mingw build works; the one extra runtime
# DLL it needs (libwinpthread-1.dll, ~50 KB) is copied into the output.
#
# Cross-compiled on Linux for x86_64-w64-mingw32. Requires: mingw-w64, nasm,
# make, wget, git, python3 + meson + ninja. Set WINE=<runner> to smoke-test.
set -euo pipefail

ffmpeg_tag="${FFMPEG_TAG:-c48230eb86ff02246f6a14fa1475a0d9398363b4}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/build/ffmpeg-minimal-libav"
deps="$work/builddeps"
src="$work/src"
dist="$work/dist"
jobs="$(nproc 2>/dev/null || echo 4)"

mkdir -p "$src" "$deps" "$dist"

# Mirror all output to a log and, on any unexpected failure, surface the tail as
# a GitHub `::error::` ANNOTATION. Raw job logs need repo admin to download, but
# annotations are readable unauthenticated, so this is how a CI failure here can
# actually be diagnosed from outside the Actions UI.
work_log="$work/build.log"
: > "$work_log" 2>/dev/null || true
exec > >(tee "$work_log") 2>&1

emit_build_error() {
  local encoded
  encoded="$(python3 - "$work_log" <<'PY' 2>/dev/null || true
import sys, urllib.parse
try:
    data = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except Exception:
    data = "no build log"
sys.stdout.write(urllib.parse.quote(data[-3500:]))
PY
)"
  echo "::error title=minimal-libav build failed::${encoded:-no build log}"
  sync || true
  sleep 1
}
trap emit_build_error ERR

fetch() { # fetch <dir> <url> [<rev>]
  local dir="$1" url="$2" rev="${3:-}"
  if [ -d "$dir" ]; then return 0; fi
  if [ -n "$rev" ]; then
    local temporary="${dir}.fetch"
    rm -rf "$temporary"
    git init "$temporary"
    git -C "$temporary" remote add origin "$url"
    git -C "$temporary" fetch --depth 1 origin "$rev"
    git -C "$temporary" checkout --detach FETCH_HEAD
    mv "$temporary" "$dir"
  else
    git clone --depth 1 "$url" "$dir"
  fi
}

cross=x86_64-w64-mingw32
# Prefer the POSIX (winpthreads) compiler variant: dav1d's meson build expects
# pthreads, and this is the exact variant scripts/build-minimal-ffmpeg-win64.sh
# already builds successfully.
cross_cc="$cross-gcc"
cross_cxx="$cross-g++"
if command -v "$cross-gcc-posix" >/dev/null 2>&1 &&
   command -v "$cross-g++-posix" >/dev/null 2>&1; then
  cross_cc="$cross-gcc-posix"
  cross_cxx="$cross-g++-posix"
fi
echo "Cross C compiler: $cross_cc"

# ---- zlib (png/webp decode) -------------------------------------------------
echo "::group::zlib"
if [ ! -f "$deps/zlib/lib/libz.a" ]; then
  fetch "$src/zlib" https://github.com/madler/zlib.git v1.3.1
  ( cd "$src/zlib"
    CC="$cross_cc" AR="$cross-ar" RANLIB="$cross-ranlib" \
      ./configure --static --prefix="$deps/zlib"
    make -j"$jobs"
    make install )
fi
echo "::endgroup::"

# ---- dav1d (AV1 decode) -----------------------------------------------------
echo "::group::dav1d"
if [ ! -f "$deps/dav1d/lib/libdav1d.a" ]; then
  fetch "$src/dav1d" https://github.com/videolan/dav1d.git
  cat > "$work/dav1d-cross.txt" <<EOF
[binaries]
c = '$cross_cc'
cpp = '$cross_cxx'
ar = '$cross-ar'
strip = '$cross-strip'
windres = '$cross-windres'
pkgconfig = '$cross-pkg-config'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
  ( cd "$src/dav1d"
    meson setup "$work/dav1d-build" --cross-file="$work/dav1d-cross.txt" \
      --buildtype=release --default-library=static --prefix="$deps/dav1d"
    ninja -C "$work/dav1d-build"
    ninja -C "$work/dav1d-build" install )
fi
echo "::endgroup::"

# ---- ffmpeg (shared, decode-only) -------------------------------------------
echo "::group::ffmpeg-libav"
if [ ! -f "$dist/bin/avcodec.dll" ]; then
  fetch "$src/ffmpeg" https://github.com/FFmpeg/FFmpeg.git "$ffmpeg_tag"
  ( cd "$src/ffmpeg"
    export PKG_CONFIG_LIBDIR="$deps/dav1d/lib/pkgconfig:$deps/zlib/lib/pkgconfig"
    if ! ./configure \
      --prefix="$dist" \
      --target-os=mingw32 --arch=x86_64 \
      --cross-prefix="$cross-" --enable-cross-compile \
      --cc="$cross_cc" --cxx="$cross_cxx" \
      --disable-doc --disable-debug \
      --disable-everything \
      --disable-programs \
      --disable-avdevice --disable-avfilter --disable-swresample \
      --disable-network --disable-autodetect \
      --enable-shared --disable-static --enable-small \
      --enable-avcodec --enable-avformat --enable-avutil --enable-swscale \
      --enable-zlib --enable-libdav1d \
      --enable-protocol=file \
      --enable-demuxer=mov,matroska,image2,gif,rawvideo \
      --enable-decoder=h264,hevc,vp8,vp9,av1,libdav1d,mpeg4,mpeg1video,mpeg2video,prores,png,mjpeg,webp,bmp,gif \
      --enable-parser=h264,hevc,vp8,vp9,av1,mpeg4video,mjpeg,png,webp,bmp,gif \
      --extra-cflags="-I$deps/zlib/include -I$deps/dav1d/include" \
      --extra-ldflags="-L$deps/zlib/lib -L$deps/dav1d/lib -static-libgcc" \
      --extra-libs="-lws2_32 -lpthread"; then
      echo "=== ffmpeg configure failed; config.log tail ==="
      tail -120 ffbuild/config.log 2>/dev/null || true
      exit 1
    fi
    if ! make -j"$jobs"; then
      echo "=== ffmpeg make failed ==="
      exit 1
    fi
    make install )
fi
echo "::endgroup::"

# ---- copy the one mingw runtime DLL the posix build needs -------------------
winpthread="$($cross_cc -print-file-name=libwinpthread-1.dll)"
if [ -n "$winpthread" ] && [ -f "$winpthread" ]; then
  cp "$winpthread" "$dist/bin/"
else
  echo "::warning::libwinpthread-1.dll not found next to $cross_cc"
fi

# ---- report -----------------------------------------------------------------
echo "::group::sizes"
ls -l "$dist/bin"
du -ch "$dist/bin"/*.dll | tail -1
echo "::endgroup::"

# ---- smoke test under wine (opt-in) -----------------------------------------
if [ -z "${WINE:-}" ]; then
  if command -v wine64 >/dev/null 2>&1; then WINE=wine64
  elif command -v wine >/dev/null 2>&1; then WINE=wine
  fi
fi
if [ -n "${WINE:-}" ]; then
  echo "::group::smoke test"
  export WINEDEBUG=-all
  # Every non-system DLL the libs import must be one we ship, so the download is
  # genuinely self-contained (the four libav DLLs + libwinpthread-1.dll).
  allowed="avcodec avformat avutil swscale libwinpthread"
  for dll in "$dist/bin"/av*.dll "$dist/bin"/sw*.dll; do
    while read -r name; do
      name="${name%.dll}"
      case "$name" in
        KERNEL32|USER32|ADVAPI32|WS2_32|SHELL32|GDI32|ole32|bcrypt|ucrtbase|VCRUNTIME*|api-ms-win*) continue ;;
      esac
      echo "$allowed" | grep -qw "$name" || {
        # Non-fatal: still upload the artifact so size/feasibility can be
        # assessed, but surface the unexpected dependency prominently.
        echo "::warning::$(basename "$dll") imports unexpected DLL: $name"
      }
    done < <($cross-objdump -p "$dll" | awk '/DLL Name:/ {print $3}')
  done
  echo "import scan complete; shipped DLLs: $(ls "$dist/bin"/*.dll | xargs -n1 basename | tr '\n' ' ')"
  echo "::endgroup::"
else
  echo "Set WINE=<wine> to run the smoke test."
fi
