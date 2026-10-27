"""Firma ZIPs y feeds con la clave del Llavero, sin exportar material privado."""
import base64
import json
import plistlib
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path

root = Path(__file__).resolve().parent.parent
config = json.loads((root / 'Config/release.json').read_text())
tools = root / '.build/vendor' / f"Sparkle-{config['sparkleVersion']}" / 'bin'
account = config['updateKeyAccount']
public = subprocess.check_output([str(tools / 'generate_keys'), '--account', account, '-p'], text=True).strip()
if public != config['updatePublicKey']:
    raise SystemExit('La clave pública del Llavero no coincide con Config/release.json. No se firmará.')
notes = (root / 'docs/releases' / f"v{config['version']}.html").read_text()
namespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', namespace)
updates = root / 'updates'
updates.mkdir(exist_ok=True)
repository = 'https://github.com/AlexandroHernandez27/imac-second-display'

for role, filename in [('Sender', 'iMac-Sender-AppleSilicon.zip'), ('Receiver', 'iMac-Receiver-universal.zip')]:
    bundle = root / 'dist' / f'iMac {role}.app'
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if info['CFBundleVersion'] != str(config['build']) or info['CFBundleShortVersionString'] != config['version']:
        raise SystemExit('Compila y empaqueta la versión actual antes de firmar.')
    archive = root / 'dist' / filename
    with zipfile.ZipFile(archive) as zipped:
        archived = plistlib.loads(zipped.read(f'iMac {role}.app/Contents/Info.plist'))
    if archived != info:
        raise SystemExit('El ZIP no corresponde a los metadatos del bundle actual; vuelve a empaquetar.')
    signature = subprocess.check_output([str(tools / 'sign_update'), '--account', account, '-p', str(archive)], text=True).strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise SystemExit('Firma de archivo inválida')
    rss = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = f'iMac {role} · actualizaciones experimentales'
    ET.SubElement(channel, 'link').text = repository
    ET.SubElement(channel, 'language').text = 'es'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f"iMac {role} {config['version']}"
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f'{{{namespace}}}version').text = str(config['build'])
    ET.SubElement(item, f'{{{namespace}}}shortVersionString').text = config['version']
    ET.SubElement(item, f'{{{namespace}}}minimumSystemVersion').text = '13.0'
    ET.SubElement(item, 'description').text = notes
    ET.SubElement(item, 'enclosure', {
        'url': f"{repository}/releases/download/v{config['version']}/{filename}",
        'length': str(archive.stat().st_size), 'type': 'application/octet-stream',
        f'{{{namespace}}}edSignature': signature,
    })
    ET.indent(rss)
    path = updates / f'{role.lower()}.xml'
    ET.ElementTree(rss).write(path, encoding='utf-8', xml_declaration=True)
    subprocess.run([str(tools / 'sign_update'), '--account', account, '-p', str(path)], check=True)
    subprocess.run([str(tools / 'sign_update'), '--account', account, '--verify', str(path)], check=True)
    print(f'Feed firmado: {path.relative_to(root)}')
