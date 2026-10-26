#!/usr/bin/env bash
# libdovi'yi (dovi_tool/dolby_vision, C API) iOS arm64 için statik XCFramework olarak derler.
# Çıktı: ThirdParty/build/Dovi.xcframework
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/versions.lock"
WORK="$HERE/work"
OUT="$HERE/build"
PREFIX="$WORK/dovi-ios"
mkdir -p "$WORK" "$OUT"

rustup target add aarch64-apple-ios
if ! command -v cargo-cinstall >/dev/null 2>&1; then
  # Hazır cargo-c ikilisi; yoksa kaynaktan derlenir.
  if curl -fsSL -o "$WORK/cargo-c.zip" https://github.com/lu-zero/cargo-c/releases/latest/download/cargo-c-macos.zip; then
    unzip -o -q "$WORK/cargo-c.zip" -d "$HOME/.cargo/bin"
  fi
  command -v cargo-cinstall >/dev/null 2>&1 || cargo install cargo-c --locked
fi

SRC="$WORK/dovi_tool"
if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$DOVI_TOOL_REF" "$DOVI_TOOL_REPO" "$SRC"
fi
echo "dovi_tool commit: $(git -C "$SRC" rev-parse HEAD)"

cd "$SRC/dolby_vision"
IPHONEOS_DEPLOYMENT_TARGET="$IOS_MIN" cargo cinstall --release --features capi \
  --target aarch64-apple-ios --library-type staticlib --prefix "$PREFIX" --libdir "$PREFIX/lib" --includedir "$PREFIX/include"

rm -rf "$OUT/Dovi.xcframework"
xcodebuild -create-xcframework -library "$PREFIX/lib/libdovi.a" -headers "$PREFIX/include" -output "$OUT/Dovi.xcframework"
echo "libdovi hazır: $OUT/Dovi.xcframework"
echo "----- libdovi C başlığı -----"
find "$PREFIX/include" -name '*.h' -print -exec cat {} \;
