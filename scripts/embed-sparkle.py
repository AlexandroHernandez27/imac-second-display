"""Copia el framework conservando enlaces, permisos y su firma original."""
import json
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
config = json.loads((root / 'Config/release.json').read_text())
vendor = root / '.build/vendor' / f"Sparkle-{config['sparkleVersion']}"
for role in sys.argv[1:]:
    if role not in ('Sender', 'Receiver'):
        raise SystemExit('Rol inválido')
    bundle = root / 'dist' / f'iMac {role}.app' / 'Contents'
    destination = bundle / 'Frameworks/Sparkle.framework'
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ditto', str(vendor / 'Sparkle.framework'), str(destination)], check=True)
    resources = bundle / 'Resources'
    resources.mkdir(exist_ok=True)
    shutil.copy2(vendor / 'LICENSE', resources / 'Sparkle-LICENSE.txt')
    shutil.copy2(root / 'THIRD_PARTY_NOTICES.md', resources / 'THIRD_PARTY_NOTICES.md')
