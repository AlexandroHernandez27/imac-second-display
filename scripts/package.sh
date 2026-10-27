#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
codesign --verify --deep --strict 'dist/iMac Sender.app'
codesign --verify --deep --strict 'dist/iMac Receiver.app'
lipo 'dist/iMac Receiver.app/Contents/MacOS/iMacReceiver' -verify_arch arm64 x86_64
# Se distribuyen archivos del bundle, sin metadatos locales ni ACLs del equipo.
ditto -c -k --norsrc --noextattr --noacl --keepParent 'dist/iMac Sender.app' dist/iMac-Sender-AppleSilicon.zip
ditto -c -k --norsrc --noextattr --noacl --keepParent 'dist/iMac Receiver.app' dist/iMac-Receiver-universal.zip
cp CONTINUAR_EN_IMAC.md dist/CONTINUAR_EN_IMAC.md
cd dist
shasum -a 256 iMac-Sender-AppleSilicon.zip iMac-Receiver-universal.zip CONTINUAR_EN_IMAC.md > SHA256SUMS.txt
python3 ../scripts/verify-package.py
echo 'ZIPs y sumas SHA-256 preparados en dist/.'
