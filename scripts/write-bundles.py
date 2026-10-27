"""Genera metadatos de las apps sin incluir datos del equipo ni credenciales."""
import plistlib
import sys
from pathlib import Path

roles = sys.argv[1:] or ["Sender", "Receiver"]
if any(role not in ("Sender", "Receiver") for role in roles):
    raise SystemExit("Rol inválido: usa Sender o Receiver")
for role in roles:
    contents = Path("dist") / f"iMac {role}.app" / "Contents"
    info = {
        "CFBundleExecutable": f"iMac{role}",
        "CFBundleIdentifier": f"local.imac-second-display.{role.lower()}",
        "CFBundleName": f"iMac {role}",
        "CFBundleDisplayName": f"iMac {role}",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "2",
        "CFBundleShortVersionString": "0.2.0",
        "LSMinimumSystemVersion": "13.0",
        "NSHighResolutionCapable": True,
        "NSLocalNetworkUsageDescription": "Conectar la MacBook y la iMac por la red local para extender el escritorio.",
        "NSScreenCaptureUsageDescription": "Transmitir únicamente la pantalla virtual a la iMac después del emparejamiento.",
    }
    with (contents / "Info.plist").open("wb") as file:
        plistlib.dump(info, file)
