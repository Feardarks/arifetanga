#!/usr/bin/env bash
# libsmb2'yi (SMB2/3 istemcisi, LGPL-2.1) iOS arm64 için statik XCFramework olarak derler (S7, AS-3/AS-23).
# Kerberos/GSSAPI kapalı: kimlik doğrulama NTLMSSP (ev NAS'ları). Çıktı: ThirdParty/build/Smb2.xcframework
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/versions.lock"
WORK="$HERE/work"
OUT="$HERE/build"
PREFIX="$WORK/smb2-ios"
mkdir -p "$WORK" "$OUT"

SRC="$WORK/libsmb2"
if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$LIBSMB2_REF" "$LIBSMB2_REPO" "$SRC"
fi
echo "libsmb2 commit: $(git -C "$SRC" rev-parse HEAD)"

# Yapılandırma denetimleri yalnızca başlık/yapı üyesi sınar; deneme derlemeleri statik kütüphane olarak
# yapılır (iOS'ta imzasız çalıştırılabilir bağlamaya gerek kalmaz).
rm -rf "$WORK/smb2-build"
cmake -S "$SRC" -B "$WORK/smb2-build" -G "Unix Makefiles" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_GSSAPI=OFF \
  -DENABLE_LIBKRB5=OFF \
  -DENABLE_EXAMPLES=OFF \
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build "$WORK/smb2-build" -j"$(sysctl -n hw.ncpu)"
cmake --install "$WORK/smb2-build"

LIB="$(find "$PREFIX" -name 'libsmb2.a' | head -1)"
test -n "$LIB"
lipo -info "$LIB"
rm -rf "$OUT/Smb2.xcframework"
xcodebuild -create-xcframework -library "$LIB" -headers "$PREFIX/include" -output "$OUT/Smb2.xcframework"
echo "libsmb2 $LIBSMB2_REF hazır: $OUT/Smb2.xcframework"
find "$OUT/Smb2.xcframework" -name '*.h' -print
