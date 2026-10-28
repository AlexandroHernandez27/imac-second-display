#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
sdk_path=$(xcrun --show-sdk-path)
xcrun swiftc -swift-version 5 -O -sdk "$sdk_path" -target arm64-apple-macosx13.0 \
  -module-cache-path .build/module-cache Sources/Shared/Support.swift Sources/Shared/Diagnostics.swift \
  Tests/DiagnosticsSmoke/main.swift -framework AppKit -framework Network -o .build/diagnostics-smoke
if [[ "${1:-}" == "--run" ]]; then .build/diagnostics-smoke; fi
