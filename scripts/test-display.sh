#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
sdk_path=$(xcrun --show-sdk-path)
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path=.build/module-cache -isysroot "$sdk_path" -mmacosx-version-min=13.0 \
  -c Sources/VirtualDisplay/VirtualDisplay.m -o .build/VirtualDisplay.o
xcrun swiftc -swift-version 5 -sdk "$sdk_path" -target arm64-apple-macosx13.0 \
  -module-cache-path .build/module-cache -import-objc-header Sources/VirtualDisplay/VirtualDisplay.h \
  Sources/Probe/main.swift .build/VirtualDisplay.o -framework AppKit -framework CoreGraphics \
  -o .build/display-probe
if [[ "${1:-}" == "--run" ]]; then
  before=$(.build/display-probe --list)
  .build/display-probe
  after=$(.build/display-probe --list)
  if [[ "$before" != "$after" ]]; then
    echo 'FAIL: la lista de pantallas no se restauró al salir del proceso.'
    exit 1
  fi
  echo 'PASS: pantalla independiente y retirada al salir del proceso.'
else
  echo 'Compilado. Ejecutar .build/display-probe en la sesión gráfica de la MacBook.'
fi
