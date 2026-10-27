"""Descarga una versión fija de Sparkle y comprueba su SHA-256 antes de extraerla."""
import hashlib
import json
import subprocess
import sys
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parent.parent
config = json.loads((root / 'Config/release.json').read_text())
version = config['sparkleVersion']
cache = root / '.build/vendor'
cache.mkdir(parents=True, exist_ok=True)
archive = cache / f'Sparkle-{version}.tar.xz'
if not archive.exists():
    url = f'https://github.com/sparkle-project/Sparkle/releases/download/{version}/Sparkle-{version}.tar.xz'
    print(f'Descargando Sparkle {version}…', file=sys.stderr)
    temporary = archive.with_suffix('.download')
    urllib.request.urlretrieve(url, temporary)
    temporary.replace(archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != config['sparkleSHA256']:
    raise SystemExit('SHA-256 de Sparkle incorrecto; no se extraerá ni ejecutará.')
destination = cache / f'Sparkle-{version}'
if not (destination / 'Sparkle.framework').exists():
    destination.mkdir(exist_ok=True)
    subprocess.run(['tar', '-xJf', str(archive), '-C', str(destination), './Sparkle.framework', './bin', './LICENSE'], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination / 'Sparkle.framework')], check=True)
print(destination)
