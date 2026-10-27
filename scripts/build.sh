#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache dist
sparkle_root=$(python3 scripts/setup-sparkle.py)
sdk_path=$(xcrun --show-sdk-path)
sender='dist/iMac Sender.app'
receiver='dist/iMac Receiver.app'
mkdir -p "$sender/Contents/MacOS" "$sender/Contents/Helpers" "$sender/Contents/Resources" \
  "$receiver/Contents/MacOS" "$receiver/Contents/Resources"

xcrun clang -fobjc-arc -fmodules -fmodules-cache-path=.build/module-cache -isysroot "$sdk_path" \
  -target arm64-apple-macos13.0 -c Sources/VirtualDisplay/VirtualDisplay.m -o .build/VirtualDisplay.o
xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" -target arm64-apple-macosx13.0 \
  -module-cache-path .build/module-cache -import-objc-header Sources/VirtualDisplay/VirtualDisplay.h \
  Sources/DisplayHelper/main.swift .build/VirtualDisplay.o -framework AppKit -framework CoreGraphics \
  -o "$sender/Contents/Helpers/DisplayHelper"
xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" -target arm64-apple-macosx13.0 \
  -module-cache-path .build/module-cache Sources/Shared/*.swift Sources/Updates/*.swift Sources/Sender/*.swift \
  -F "$sparkle_root" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework AppKit -framework Network -framework Security -framework ScreenCaptureKit \
  -framework VideoToolbox -framework CoreMedia -o "$sender/Contents/MacOS/iMacSender"
for arch in arm64 x86_64; do
  xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" -target "$arch-apple-macosx13.0" \
    -module-cache-path .build/module-cache Sources/Shared/*.swift Sources/Updates/*.swift Sources/Receiver/*.swift \
    -F "$sparkle_root" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework AppKit -framework Network -framework Security -framework AVFoundation \
    -framework CoreMedia -o ".build/iMacReceiver-$arch"
done
lipo -create .build/iMacReceiver-arm64 .build/iMacReceiver-x86_64 -output "$receiver/Contents/MacOS/iMacReceiver"

python3 scripts/write-bundles.py
python3 scripts/embed-sparkle.py Sender Receiver
codesign --force --sign - "$sender/Contents/Helpers/DisplayHelper"
codesign --force --sign - "$sender"
codesign --force --sign - "$receiver"
echo 'Aplicaciones listas en dist/. Firma local ad hoc; no están notarizadas.'
