#!/usr/bin/env bash
# FFmpeg'i iOS arm64 için statik XCFramework olarak derler (LGPL; --disable-gpl --disable-nonfree).
# Çıktı: ThirdParty/build/FFmpeg.xcframework
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/versions.lock"
WORK="$HERE/work"
OUT="$HERE/build"
PREFIX="$WORK/ffmpeg-ios"
mkdir -p "$WORK" "$OUT"

SRC="$WORK/FFmpeg-n$FFMPEG_VERSION"
if [ ! -d "$SRC" ]; then
  curl -fsSL "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$FFMPEG_VERSION.tar.gz" | tar xz -C "$WORK"
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
FLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$IOS_MIN"

cd "$SRC"
./configure \
  --prefix="$PREFIX" \
  --enable-cross-compile --target-os=darwin --arch=aarch64 \
  --cc="$CC" --sysroot="$SDK" \
  --extra-cflags="$FLAGS" --extra-ldflags="$FLAGS" \
  --disable-programs --disable-doc --disable-debug \
  --disable-shared --enable-static --enable-pic \
  --disable-gpl --disable-nonfree --disable-autodetect --enable-zlib \
  --disable-everything \
  --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample \
  --enable-protocol=file \
  --enable-demuxer=matroska,mov,mpegts \
  --enable-parser=hevc,h264,av1,vc1,mpeg4video,mpegvideo,ac3,aac,dca,mlp,flac,opus \
  --enable-bsf=hevc_mp4toannexb,h264_mp4toannexb,extract_extradata
make -j"$(sysctl -n hw.ncpu)"
make install

# Üç kütüphaneyi tek statik arşivde birleştir ve XCFramework'e sar.
libtool -static -o "$WORK/libffmpeg.a" "$PREFIX/lib/libavformat.a" "$PREFIX/lib/libavcodec.a" "$PREFIX/lib/libavutil.a"
rm -rf "$OUT/FFmpeg.xcframework"
xcodebuild -create-xcframework -library "$WORK/libffmpeg.a" -headers "$PREFIX/include" -output "$OUT/FFmpeg.xcframework"
echo "FFmpeg n$FFMPEG_VERSION hazır: $OUT/FFmpeg.xcframework"
