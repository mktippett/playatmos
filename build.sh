#!/bin/bash
# Builds build/PlayAtmos.app and build/atmostest.
# Requires: Xcode Command Line Tools (clang) and Homebrew ffmpeg (libavformat/libavcodec/libavutil).
set -euo pipefail
cd "$(dirname "$0")"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
FF=(-I"$BREW/include" -L"$BREW/lib" -lavformat -lavcodec -lavutil -lswresample -Wl,-rpath,"$BREW/lib")
CF=(-fobjc-arc -O2 -Wall -Wno-four-char-constants -Wno-deprecated-declarations)
SRC=(src/Segmenter.m src/HLSServer.m src/Subtitles.m)

APP=build/PlayAtmos.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang "${CF[@]}" src/main.m "${SRC[@]}" "${FF[@]}" \
  -framework Cocoa -framework AVKit -framework AVFoundation -framework CoreMedia -framework CoreAudio \
  -o "$APP/Contents/MacOS/PlayAtmos"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP" >/dev/null 2>&1 || true

clang "${CF[@]}" tools/atmostest.m "${SRC[@]}" "${FF[@]}" \
  -framework AVFoundation -framework CoreMedia -framework AudioToolbox -framework CoreAudio \
  -framework CoreVideo -framework QuartzCore -framework Cocoa -o build/atmostest
echo "built $APP and build/atmostest"
clang "${CF[@]}" tools/capture.m -framework Foundation -framework AudioToolbox -framework CoreAudio -o build/capture
clang "${CF[@]}" tools/subtest.m src/Subtitles.m "${FF[@]}" -framework Cocoa -o build/subtest
