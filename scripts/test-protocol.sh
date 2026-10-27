#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
sdk_path=$(xcrun --show-sdk-path)
xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" -target arm64-apple-macosx13.0 \
  -module-cache-path .build/module-cache Sources/Shared/*.swift Sources/Receiver/FrameReceiver.swift Tests/ProtocolSmoke/main.swift \
  -framework AppKit -framework Network -framework Security -framework VideoToolbox \
  -framework CoreMedia -o .build/protocol-smoke
if [[ "${1:-}" == "--run" ]]; then .build/protocol-smoke; fi
