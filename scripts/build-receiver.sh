#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache 'dist/iMac Receiver.app/Contents/MacOS'
sparkle_root=$(python3 scripts/setup-sparkle.py)
sdk_path=$(xcrun --show-sdk-path)
build_arch=$(uname -m)
case "$build_arch" in
  arm64|x86_64) ;;
  *) echo 'Arquitectura no admitida.'; exit 1 ;;
esac
xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" -target "$build_arch-apple-macosx13.0" \
  -module-cache-path .build/module-cache Sources/Shared/*.swift Sources/Updates/*.swift Sources/Receiver/*.swift \
  -F "$sparkle_root" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -framework AppKit -framework Network -framework Security -framework AVFoundation \
  -framework CoreMedia -o 'dist/iMac Receiver.app/Contents/MacOS/iMacReceiver'
python3 scripts/write-bundles.py Receiver
python3 scripts/embed-sparkle.py Receiver
codesign --force --sign - 'dist/iMac Receiver.app'
echo "Receptor local compilado para $build_arch. No reemplaza una release universal."
