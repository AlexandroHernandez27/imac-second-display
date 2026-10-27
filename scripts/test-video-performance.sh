#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
sdk_path=$(xcrun --show-sdk-path)
xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" -target arm64-apple-macosx13.0 \
  -module-cache-path .build/module-cache Sources/Shared/*.swift Sources/Sender/CapturePipeline.swift \
  Sources/Receiver/FrameReceiver.swift Tests/VideoBenchmark/main.swift \
  -framework AppKit -framework Network -framework Security -framework ScreenCaptureKit \
  -framework VideoToolbox -framework CoreMedia -o .build/video-benchmark
if [[ "${1:-}" == "--run" ]]; then shift; .build/video-benchmark "$@"; fi
