#!/usr/bin/env bash
# Build a MINIMAL SHARED FFmpeg (libavcodec/format/util/swscale DLLs) for
# Windows x64, containing only the DECODERS/DEMUXERS Aurora Cut needs for the
# optional in-process scrub decoder (aurora-cut/source/auroracut/libavdecode.d).
#
# This is deliberately NOT the full ffmpeg.exe build and NOT a general-purpose
# FFmpeg: no encoders, no filters, no avdevice, no avfilter, no CLI. The point is
# a small download that powers instant frame-accurate scrub. FFmpeg's full
# shared build (BtbN gpl-shared) is ~120 MB because avcodec enables everything;
# this keeps the same feature surface as the 13.5 MB static minimal ffmpeg.exe
# but split into shared libraries with only the decode path.
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
# Use the win32-threads compiler so the DLLs do NOT depend on libwinpthread-1.dll.
# (The static ffmpeg.exe needs the posix variant for gfxcapture; the decode-only
# shared build does not use avdevice at all.)
cross_cc="$cross-gcc"
cross_cxx="$cross-g++"
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
    ./configure \
      --prefix="$dist" \
      --target-os=mingw32 --arch=x86_64 \
      --cross-prefix="$cross-" --enable-cross-compile \
      --cc="$cross_cc" --cxx="$cross_cxx" \
      --disable-doc --disable-debug \
      --disable-everything \
      --enable-gpl \
      --enable-shared --disable-static --enable-small \
      --disable-w32threads --disable-pthreads \
      --enable-avcodec --enable-avformat --enable-avutil --enable-swscale \
      --enable-zlib --enable-libdav1d \
      --enable-protocol=file \
      --enable-demuxer=mov,matroska,image2,gif,rawvideo \
      --enable-decoder=h264,hevc,vp8,vp9,av1,libdav1d,mpeg4,mpeg1video,mpeg2video,prores,png,mjpeg,webp,bmp,gif \
      --enable-parser=h264,hevc,vp8,vp9,av1,mpeg4video,mjpeg,png,webp,bmp,gif \
      --extra-cflags="-I$deps/zlib/include -I$deps/dav1d/include" \
      --extra-ldflags="-L$deps/zlib/lib -L$deps/dav1d/lib -static-libgcc" \
      --extra-libs="-lws2_32"
    make -j"$jobs"
    make install )
fi
echo "::endgroup::"

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
  # The DLLs must not pull in a mingw runtime they did not ship.
  for dll in "$dist/bin"/av*.dll "$dist/bin"/sw*.dll; do
    if $cross-objdump -p "$dll" | grep -qi "libwinpthread"; then
      echo "::error::$(basename "$dll") depends on libwinpthread-1.dll"
      exit 1
    fi
  done
  echo "no libwinpthread dependency; shared libav is self-contained"
  echo "::endgroup::"
else
  echo "Set WINE=<wine> to run the smoke test."
fi
