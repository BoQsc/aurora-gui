#!/usr/bin/env bash
# Build a minimal static ffmpeg.exe + ffprobe.exe for Windows x64, containing
# only the codecs/filters Aurora Cut actually uses. Runs on a Linux host and
# cross-compiles for x86_64-w64-mingw32.
#
# Requires: mingw-w64, nasm, pkg-config-mingw-w64-x86-64, make, wget, git,
# python3 + meson + ninja. Set WINE=<runner> to also smoke-test the result.
set -euo pipefail

ffmpeg_tag="${FFMPEG_TAG:-n8.1}"
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
    git clone --depth 1 --branch "$rev" "$url" "$dir"
  else
    git clone --depth 1 "$url" "$dir"
  fi
}

# ---- cross tools -------------------------------------------------------------
cross=x86_64-w64-mingw32

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
  fetch "$src/nv-codec-headers" https://github.com/FFmpeg/nv-codec-headers.git
  ( cd "$src/nv-codec-headers"
    make install PREFIX="$deps/nv" )
fi
echo "::endgroup::"

# ---- ffmpeg -----------------------------------------------------------------
echo "::group::ffmpeg"
if [ ! -x "$dist/bin/ffmpeg.exe" ]; then
  fetch "$src/ffmpeg" https://github.com/FFmpeg/FFmpeg.git "$ffmpeg_tag"
  ( cd "$src/ffmpeg"
    export PKG_CONFIG_LIBDIR=
    ./configure \
      --prefix="$dist" \
      --target-os=mingw32 --arch=x86_64 \
      --cross-prefix="$cross-" --enable-cross-compile \
      --disable-doc --disable-debug --disable-avdevice \
      --disable-network --disable-everything \
      --enable-static --disable-shared --enable-small \
      --enable-avcodec --enable-avformat --enable-avfilter \
      --enable-swscale --enable-swresample \
      --enable-protocol=file,pipe \
      --enable-libx264 --enable-libmp3lame --enable-libdav1d \
      --enable-zlib --enable-nvenc \
      --enable-hwaccel=d3d11va,dxva2 \
      --enable-demuxer=lavfi,mov,matroska,mp3,wav,flac,ogg,image2,gif,rawvideo \
      --enable-muxer=mp4,mp3,image2,rawvideo,s16le,null \
      --enable-decoder=h264,hevc,vp8,vp9,av1,libdav1d,mpeg4,mpeg1video,mpeg2video,prores \
      --enable-decoder=png,mjpeg,webp,bmp,gif \
      --enable-decoder=aac,mp3,flac,vorbis,opus,ac3,eac3 \
      --enable-decoder=pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_s16be,pcm_s24be,pcm_s32be \
      --enable-decoder=pcm_u8,pcm_s8,pcm_alaw,pcm_mulaw,adpcm_ima_wav \
      --enable-encoder=libx264,h264_nvenc,aac,libmp3lame,ppm \
      --enable-parser=h264,hevc,vp8,vp9,av1,mpeg4video,mpegvideo,mjpeg,png,webp,bmp,gif \
      --enable-parser=aac,mp3,flac,vorbis,opus,mpegaudio,ac3,eac3 \
      --enable-filter=color,anullsrc,testsrc2,format,scale,pad,crop,overlay,setpts \
      --enable-filter=fps,trim,reverse,setsar,geq,drawbox,rotate,colorchannelmixer \
      --enable-filter=fade,gblur,split,aresample,aformat,volume,afade,adelay \
      --enable-filter=amix,atrim,alimiter,atempo,areverse,showwavespic \
      --extra-cflags="-I$deps/zlib/include -I$deps/x264/include -I$deps/lame/include -I$deps/dav1d/include -I$deps/nv/include" \
      --extra-ldflags="-L$deps/zlib/lib -L$deps/x264/lib -L$deps/lame/lib -L$deps/dav1d/lib" \
      --extra-libs="-lws2_32 -lpthread"
    make -j"$jobs"
    make install )
fi
echo "::endgroup::"

# ---- report -----------------------------------------------------------------
echo "::group::sizes"
du -h "$dist/bin/ffmpeg.exe" "$dist/bin/ffprobe.exe"
echo "::endgroup::"

# ---- smoke test under wine (opt-in) -----------------------------------------
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
  echo "Set WINE=<wine64> to run the smoke test."
fi
