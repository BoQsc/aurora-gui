#!/usr/bin/env bash
# Build a minimal static ffmpeg.exe + ffprobe.exe for Windows x64, containing
# only the codecs/filters/devices both Aurora apps use. Runs on a Linux host
# and cross-compiles for x86_64-w64-mingw32.
#
# Covers TWO surfaces from the same binary:
# - aurora-cut: import/playback/composite/export (mp4+mp3), lavfi color/
#   anullsrc/testsrc2, d3d11va/dxva2 decode, nvenc/qsv/amf + libx264 encode.
# - aurora-stream: gfxcapture/ddagrab/gdigrab/dshow capture, rawvideo+pipe:0 canvas,
#   sdp+udp/rtp audio input, flv+fifo muxing to rtmp/rtmps (schannel TLS),
#   settb/asetpts/hwdownload filters.
#
# Requires: mingw-w64, nasm, pkg-config-mingw-w64-x86-64, make, cmake, wget,
# git, python3 + meson + ninja. Set WINE=<runner> to also smoke-test the result.
#
# GPU encoders are Aurora Cut's primary encoders (media.d probes nvenc -> qsv ->
# amf before libx264), so all three are kept: h264_nvenc, h264_qsv, h264_amf.
# - FFmpeg is pinned to the first verified post-8.1 revision used for Aurora's
#   Windows Graphics Capture HWND path. This keeps the build reproducible while
#   providing the `gfxcapture` source that correctly captures VLC's composed
#   Direct3D video surface.
# - AMF is header-only (AMF/core/Version.h), runtime loads amfrt64.dll.
# - libvpl (oneVPL) is cross-built with CMake for h264_qsv. It is C++, so the
#   ffmpeg link adds -lstdc++ and -static (embeds libstdc++/libgcc/winpthread so
#   ffmpeg.exe stays a single self-contained file).
set -euo pipefail

ffmpeg_tag="${FFMPEG_TAG:-c48230eb86ff02246f6a14fa1475a0d9398363b4}"
mingw_headers_tag="${MINGW_HEADERS_TAG:-v14.0.0}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$root/build/ffmpeg-minimal"
deps="$work/builddeps"
src="$work/src"
dist="$work/dist"
jobs="$(nproc 2>/dev/null || echo 4)"

mkdir -p "$src"
mkdir -p "$deps"

fetch() { # fetch <dir> <url> [<rev>]
  local dir="$1" url="$2" rev="${3:-}"
  if [ -d "$dir" ]; then return 0; fi
  if [ -n "$rev" ]; then
    # `git clone --branch` accepts only advertised branch/tag names, not the
    # immutable commit SHA used for FFmpeg. A one-commit fetch handles branches,
    # tags, and exact revisions while keeping the checkout reproducible.
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

# ---- cross tools -------------------------------------------------------------
cross=x86_64-w64-mingw32

# ---- current Windows SDK-compatible MinGW headers ---------------------------
# Ubuntu 24.04 currently ships MinGW-w64 11 headers. They predate the WinRT
# interop declarations required by FFmpeg's gfxcapture filter, so configure
# silently disables that filter even when it is explicitly requested. Overlay
# a pinned, newer header set while retaining the distribution's compiler,
# libraries, and CRT.
echo "::group::mingw-w64 headers"
mingw_headers="$deps/mingw-w64/include"
if [ ! -f "$mingw_headers/windows.graphics.capture.interop.h" ]; then
  fetch "$src/mingw-w64" https://github.com/mingw-w64/mingw-w64.git "$mingw_headers_tag"
  ( cd "$src/mingw-w64/mingw-w64-headers"
    ./configure --host="$cross" --prefix="$deps/mingw-w64"
    make -j"$jobs"
    make install )
fi
for required_header in \
  dispatcherqueue.h \
  windows.graphics.capture.h \
  windows.graphics.capture.interop.h \
  windows.graphics.directx.direct3d11.h; do
  if [ ! -f "$mingw_headers/$required_header" ]; then
    echo "::error::MinGW-w64 $mingw_headers_tag did not install $required_header"
    exit 1
  fi
done
echo "Using MinGW-w64 $mingw_headers_tag header overlay: $mingw_headers"
echo "::endgroup::"

# ---- zlib (png/webp decode) -------------------------------------------------
echo "::group::zlib"
if [ ! -f "$deps/zlib/lib/libz.a" ]; then
  fetch "$src/zlib" https://github.com/madler/zlib.git v1.3.1
  ( cd "$src/zlib"
    CC="$cross-gcc" AR="$cross-ar" RANLIB="$cross-ranlib" \
      ./configure --static --prefix="$deps/zlib"
    make -j"$jobs"
    make install )
fi
echo "::endgroup::"

# ---- libx264 ----------------------------------------------------------------
echo "::group::libx264"
if [ ! -f "$deps/x264/lib/libx264.a" ]; then
  fetch "$src/x264" https://code.videolan.org/videolan/x264.git stable
  ( cd "$src/x264"
    ./configure --host="$cross" --cross-prefix="$cross-" \
      --enable-static --disable-cli --disable-opencl --prefix="$deps/x264"
    make -j"$jobs"
    make install )
fi
echo "::endgroup::"

# ---- libmp3lame -------------------------------------------------------------
echo "::group::libmp3lame"
if [ ! -f "$deps/lame/lib/libmp3lame.a" ]; then
  if [ ! -d "$src/lame" ]; then
    mkdir -p "$src"
    wget -q -O "$src/lame-3.100.tar.gz" \
      https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
    tar xzf "$src/lame-3.100.tar.gz" -C "$src"
    mv "$src/lame-3.100" "$src/lame"
  fi
  ( cd "$src/lame"
    ./configure --host="$cross" --prefix="$deps/lame" \
      --disable-shared --enable-static --disable-frontend \
      --disable-gtktest --disable-oggtest --disable-cpml --disable-rpath
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
c = '$cross-gcc'
cpp = '$cross-g++'
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

# ---- nv-codec-headers (h264_nvenc) ------------------------------------------
echo "::group::nv-codec-headers"
if [ ! -f "$deps/nv/include/ffnvcodec/nvEncodeAPI.h" ]; then
  fetch "$src/nv-codec-headers" https://github.com/FFmpeg/nv-codec-headers.git n12.2.72.0
  ( cd "$src/nv-codec-headers"
    make install PREFIX="$deps/nv" )
fi
echo "::endgroup::"

# ---- AMF headers (h264_amf) -------------------------------------------------
echo "::group::amf"
if [ ! -f "$deps/amf/include/AMF/core/Version.h" ]; then
  fetch "$src/amf" https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git v1.5.2
  mkdir -p "$deps/amf/include/AMF"
  cp -r "$src/amf/amf/public/include/core" "$deps/amf/include/AMF/"
  cp -r "$src/amf/amf/public/include/components" "$deps/amf/include/AMF/"
fi
echo "::endgroup::"

# ---- libvpl / oneVPL (h264_qsv) ---------------------------------------------
echo "::group::libvpl"
if [ ! -f "$deps/libvpl/include/vpl/mfx.h" ]; then
  fetch "$src/libvpl" https://github.com/intel/libvpl.git
  ( cd "$src/libvpl"
    cmake -S . -B "$work/libvpl-build" \
      -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
      -DCMAKE_C_COMPILER="$cross-gcc" -DCMAKE_CXX_COMPILER="$cross-g++" \
      -DCMAKE_RC_COMPILER="$cross-windres" \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTS=OFF \
      -DBUILD_PREVIEW=OFF -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_INSTALL_PREFIX="$deps/libvpl"
    cmake --build "$work/libvpl-build" -j"$jobs"
    cmake --install "$work/libvpl-build" )
fi
echo "--- libvpl install inspection ---"
find "$deps/libvpl" -maxdepth 4 \( -name 'vpl.pc' -o -name 'libvpl*.a' -o -name 'vpl*.dll' \) -print
vpl_pc="$(find "$deps/libvpl" -name vpl.pc | head -1)"
if [ -z "$vpl_pc" ]; then
  echo "::error::vpl.pc not installed under $deps/libvpl"
  find "$deps/libvpl" -maxdepth 5
  exit 1
fi
vpl_pc_dir="$(dirname "$vpl_pc")"
echo "vpl.pc: $vpl_pc"
if ! PKG_CONFIG_LIBDIR="$vpl_pc_dir" pkg-config --print-errors --exists 'vpl >= 2.6'; then
  echo "::error::pkg-config cannot resolve 'vpl >= 2.6' from $vpl_pc"
  cat "$vpl_pc"
  exit 1
fi
echo "resolved vpl: $(PKG_CONFIG_LIBDIR="$vpl_pc_dir" pkg-config --modversion vpl)"
echo "::endgroup::"

# ---- ffmpeg -----------------------------------------------------------------
echo "::group::ffmpeg"
if [ ! -x "$dist/bin/ffmpeg.exe" ]; then
  fetch "$src/ffmpeg" https://github.com/FFmpeg/FFmpeg.git "$ffmpeg_tag"
  ( cd "$src/ffmpeg"
    export PKG_CONFIG_LIBDIR="$vpl_pc_dir:$deps/nv/lib/pkgconfig:$deps/dav1d/lib/pkgconfig:$deps/x264/lib/pkgconfig:$deps/lame/lib/pkgconfig:$deps/zlib/lib/pkgconfig"
    if ! ./configure \
      --prefix="$dist" \
      --target-os=mingw32 --arch=x86_64 \
      --cross-prefix="$cross-" --enable-cross-compile \
      --disable-doc --disable-debug \
      --disable-everything \
      --enable-gpl \
      --enable-static --disable-shared --enable-small \
      --enable-avcodec --enable-avformat --enable-avfilter \
      --enable-avdevice --enable-swscale --enable-swresample \
      --enable-schannel \
      --enable-protocol=file,pipe,udp,rtp,rtmp,rtmps \
      --enable-libx264 --enable-libmp3lame --enable-libdav1d \
      --enable-zlib --enable-nvenc --enable-amf --enable-libvpl \
      --enable-hwaccel=d3d11va,dxva2 \
      --enable-indev=lavfi,dshow,gdigrab \
      --enable-demuxer=mov,matroska,mp3,wav,flac,ogg,image2,gif,rawvideo,sdp \
      --enable-muxer=mp4,mp3,image2,rawvideo,s16le,null,flv,fifo \
      --enable-decoder=h264,hevc,vp8,vp9,av1,libdav1d,mpeg4,mpeg1video,mpeg2video,prores,wrapped_avframe,rawvideo \
      --enable-decoder=png,mjpeg,webp,bmp,gif \
      --enable-decoder=aac,mp3,flac,vorbis,opus,ac3,eac3 \
      --enable-decoder=pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_s16be,pcm_s24be,pcm_s32be \
      --enable-decoder=pcm_u8,pcm_s8,pcm_alaw,pcm_mulaw,adpcm_ima_wav \
      --enable-encoder=libx264,h264_nvenc,h264_qsv,h264_amf,aac,libmp3lame,ppm,rawvideo,pcm_s16le,null \
      --enable-parser=h264,hevc,vp8,vp9,av1,mpeg4video,mpegvideo,mjpeg,png,webp,bmp,gif \
      --enable-parser=aac,mp3,flac,vorbis,opus,mpegaudio,ac3,eac3 \
      --enable-filter=color,anullsrc,testsrc2,sine,format,scale,pad,crop,overlay,setpts \
      --enable-filter=fps,trim,reverse,setsar,geq,drawbox,rotate,colorchannelmixer \
      --enable-filter=fade,gblur,split,aresample,aformat,volume,afade,adelay \
      --enable-filter=amix,atrim,alimiter,atempo,areverse,showwavespic,settb,asetpts,hwdownload,ddagrab,gfxcapture \
      --extra-cflags="-I$mingw_headers -I$deps/zlib/include -I$deps/x264/include -I$deps/lame/include -I$deps/dav1d/include -I$deps/nv/include -I$deps/amf/include -I$deps/libvpl/include" \
      --extra-ldflags="-L$deps/zlib/lib -L$deps/x264/lib -L$deps/lame/lib -L$deps/dav1d/lib -L$deps/libvpl/lib -static" \
      --extra-libs="-lstdc++ -lws2_32 -lpthread"; then
      echo "=== ffmpeg configure failed; ffbuild/config.log tail ==="
      tail -120 ffbuild/config.log 2>/dev/null || true
      exit 1
    fi
    if ! grep -q '^CONFIG_GFXCAPTURE_FILTER=yes$' ffbuild/config.mak; then
      echo "::error::FFmpeg configure omitted gfxcapture; verify the WinRT/MinGW header overlay"
      grep -n -E 'gfxcapture|IGraphicsCapture|Windows.Graphics.Capture' ffbuild/config.log | tail -80 || true
      exit 1
    fi
    make -j"$jobs"
    make install )
fi
echo "::endgroup::"

# ---- report -----------------------------------------------------------------
echo "::group::sizes"
du -h "$dist/bin/ffmpeg.exe" "$dist/bin/ffprobe.exe"
echo "::endgroup::"

# ---- smoke test under wine (opt-in) -----------------------------------------
if [ -z "${WINE:-}" ]; then
  if command -v wine64 >/dev/null 2>&1; then WINE=wine64
  elif command -v wine >/dev/null 2>&1; then WINE=wine
  fi
fi
if [ -n "${WINE:-}" ]; then
  echo "::group::smoke test"
  out="$work/smoke"
  mkdir -p "$out"
  export WINEDEBUG=-all
  "$WINE" "$dist/bin/ffmpeg.exe" -version >/dev/null
  "$WINE" "$dist/bin/ffmpeg.exe" -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=blue:size=320x180:rate=24" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 1.25 \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    -c:a aac -b:a 128k -shortest "$out/base-av.mp4"
  "$WINE" "$dist/bin/ffmpeg.exe" -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=red:size=160x90:rate=24" -t 0.8 \
    -an -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$out/overlay.mp4"
  "$WINE" "$dist/bin/ffmpeg.exe" -hide_banner -loglevel error -y \
    -f lavfi -i "sine=frequency=660:sample_rate=48000" -t 0.75 \
    -c:a libmp3lame -q:a 4 "$out/extra.mp3"
  "$WINE" "$dist/bin/ffprobe.exe" -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height \
    -of default=noprint_wrappers=1 "$out/base-av.mp4"
  "$WINE" "$dist/bin/ffprobe.exe" -v error -select_streams a:0 \
    -show_entries stream=codec_name,channels,sample_rate \
    -of default=noprint_wrappers=1 "$out/base-av.mp4"
  "$WINE" "$dist/bin/ffprobe.exe" -v error -select_streams a:0 \
    -show_entries stream=codec_name,channels,sample_rate \
    -of default=noprint_wrappers=1 "$out/extra.mp3"
  echo "smoke test passed"
  echo "::endgroup::"
else
  echo "Set WINE=<wine> to run the smoke test."
fi
