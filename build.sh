#!/usr/bin/env bash
# Builds build/WhistleFlow.app.   ./build.sh [run|install]
set -euo pipefail
cd "$(dirname "$0")"

APP=build/WhistleFlow.app
HF=https://huggingface.co/Cactus-Compute

fetch() {
  [[ -f $2 ]] && return
  echo "↓ $2"
  mkdir -p "$(dirname "$2")"
  curl -fL --progress-bar -o "$2.part" "$1" && mv "$2.part" "$2"
}
fetch "$HF/whistle/resolve/main/whistle.cact" vendor/whistle.cact
fetch "$HF/needle3/resolve/main/macos-arm64/libneedle.a" vendor/macos-arm64/libneedle.a
fetch "$HF/needle3/resolve/main/macos-arm64/needle.h" vendor/macos-arm64/needle.h

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header vendor/macos-arm64/needle.h \
  Sources/*.swift \
  -Lvendor/macos-arm64 -lneedle -lc++ \
  -o "$APP/Contents/MacOS/WhistleFlow" \
  2> >(grep -v "was built for newer 'macOS' version" >&2)  # libneedle.a is stamped 26.0 but only needs libc/libc++
cp Resources/Info.plist "$APP/Contents/"
cp vendor/whistle.cact "$APP/Contents/Resources/"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
# Ad-hoc by default. Set SIGN_IDENTITY to a real certificate so macOS keeps permissions across rebuilds.
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier dev.local.whistleflow "$APP"
if [[ -z ${SIGN_IDENTITY:-} ]]; then
  # An ad-hoc signature changes on every build, and macOS ties the Accessibility grant to it: the old
  # toggle stays "on" in System Settings but no longer applies. Clear it so the app asks again.
  tccutil reset Accessibility dev.local.whistleflow >/dev/null 2>&1 || true
fi
echo "✓ $APP"

quit_running() {
  pkill -x WhistleFlow || true
  # `open` fails with error -600 if it runs while the old instance is still exiting.
  while pgrep -x WhistleFlow >/dev/null; do sleep 0.2; done
  sleep 0.5
}

case "${1:-}" in
  run)
    quit_running
    open "$APP"
    ;;
  install)
    quit_running
    rm -rf /Applications/WhistleFlow.app
    cp -R "$APP" /Applications/
    open /Applications/WhistleFlow.app
    ;;
esac
