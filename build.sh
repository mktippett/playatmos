#!/bin/bash
# Builds build/PlayAtmos.app and build/atmostest.
# Requires: Xcode Command Line Tools (clang) and Homebrew ffmpeg (libavformat/libavcodec/libavutil).
set -euo pipefail
cd "$(dirname "$0")"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
FF=(-I"$BREW/include" -L"$BREW/lib" -lavformat -lavcodec -lavutil -lswresample -lswscale -Wl,-rpath,"$BREW/lib")
CF=(-fobjc-arc -O2 -Wall -Wno-four-char-constants -Wno-deprecated-declarations)
SRC=(src/Segmenter.m src/HLSServer.m src/Subtitles.m)

APP=build/PlayAtmos.app
rm -rf "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"
clang "${CF[@]}" src/main.m "${SRC[@]}" "${FF[@]}" \
  -framework Cocoa -framework AVKit -framework AVFoundation -framework CoreMedia -framework CoreAudio \
  -o "$APP/Contents/MacOS/PlayAtmos"
cp Info.plist "$APP/Contents/Info.plist"
# App icon: drawn by tools/makeicon, rebuilt only when its source changes.
if [ ! -f build/AppIcon.icns ] || [ tools/makeicon.m -nt build/AppIcon.icns ]; then
  clang "${CF[@]}" tools/makeicon.m -framework Cocoa -o build/makeicon
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  build/makeicon build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((2*s)) $((2*s)) build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP" >/dev/null 2>&1 || true

clang "${CF[@]}" tools/atmostest.m "${SRC[@]}" "${FF[@]}" \
  -framework AVFoundation -framework CoreMedia -framework AudioToolbox -framework CoreAudio \
  -framework CoreVideo -framework QuartzCore -framework Cocoa -o build/atmostest
echo "built $APP and build/atmostest"
clang "${CF[@]}" tools/capture.m -framework Foundation -framework AudioToolbox -framework CoreAudio -o build/capture
clang "${CF[@]}" tools/subtest.m src/Subtitles.m "${FF[@]}" -framework Cocoa -o build/subtest
