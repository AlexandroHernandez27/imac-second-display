#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
sdk_path=$(xcrun --show-sdk-path)
xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" -target arm64-apple-macosx13.0 \
  -module-cache-path .build/module-cache Sources/Shared/*.swift Sources/Sender/CapturePipeline.swift \
  Sources/Receiver/VideoDecoder.swift Tests/LinkSmoke/main.swift \
  -framework AppKit -framework Network -framework Security -framework ScreenCaptureKit \
  -framework VideoToolbox -framework CoreMedia -framework IOKit -framework SystemConfiguration \
  -o .build/link-smoke
# --require-usb exige el cable USB-A → USB-C conectado a la iMac.
if [[ "${1:-}" == "--run" ]]; then shift; .build/link-smoke "$@"; fi
