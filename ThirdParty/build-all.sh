#!/usr/bin/env bash
# Tüm native bağımlılıkları derler (macOS + Xcode gerekir). CI'da önbellek boşsa çalışır.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
"$HERE/build-ffmpeg.sh"
"$HERE/build-libdovi.sh"
"$HERE/build-libsmb2.sh"
ls -la "$HERE/build"
