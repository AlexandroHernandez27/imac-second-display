"""Construye dos apps aisladas para ensayar la UI e instalación real de Sparkle.
No usa la clave de producción ni modifica Sender/Receiver instalados.
"""
import base64
import json
import plistlib
import subprocess
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parent.parent
config = json.loads((root / 'Config/release.json').read_text())
vendor = Path(subprocess.check_output(['python3', str(root / 'scripts/setup-sparkle.py')], text=True).strip())
fixture = root / '.build' / ('update-smoke-' + uuid.uuid4().hex[:8])
server = fixture / 'server'; server.mkdir(parents=True)
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
swift = ['xcrun', 'swiftc', '-swift-version', '5', '-O', '-sdk', sdk, '-target', 'arm64-apple-macosx13.0',
         '-module-cache-path', str(root / '.build/module-cache')]
binary = fixture / 'TestUpdater'
subprocess.run(swift + [str(root / 'Sources/Shared/Support.swift'), str(root / 'Sources/Updates/AppUpdater.swift'),
    str(root / 'Tests/UpdateSmoke/main.swift'), '-F', str(vendor), '-framework', 'Sparkle', '-framework', 'AppKit',
    '-framework', 'Network', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks', '-o', str(binary)], check=True)
for name in ('TestKey', 'VerifySignature'):
    subprocess.run(swift + ['-parse-as-library', str(root / f'Tests/UpdateSmoke/{name}.swift'), '-o', str(fixture / name)], check=True)
private = fixture / 'test-key'
public = subprocess.check_output([str(fixture / 'TestKey'), str(private)], text=True).strip()
identifier = 'local.imac-second-display.update-test.' + uuid.uuid4().hex

for folder, build in [('installed', 1), ('candidate', 2)]:
    bundle = fixture / folder / 'iMac Update Test.app'
    contents = bundle / 'Contents'
    (contents / 'MacOS').mkdir(parents=True)
    subprocess.run(['ditto', str(binary), str(contents / 'MacOS/TestUpdater')], check=True)
    subprocess.run(['ditto', str(vendor / 'Sparkle.framework'), str(contents / 'Frameworks/Sparkle.framework')], check=True)
    info = {'CFBundleExecutable': 'TestUpdater', 'CFBundleIdentifier': identifier, 'CFBundleName': 'iMac Update Test',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': str(build), 'CFBundleShortVersionString': f'0.0.{build}',
        'CFBundleDevelopmentRegion': 'es', 'LSMinimumSystemVersion': '13.0',
        'SUFeedURL': 'http://127.0.0.1:18777/appcast.xml', 'SUPublicEDKey': public,
        'SUEnableAutomaticChecks': False, 'SUAllowsAutomaticUpdates': False, 'SUAutomaticallyUpdate': False,
        'SUEnableSystemProfiling': False, 'SUVerifyUpdateBeforeExtraction': True, 'SURequireSignedFeed': True,
        'SUSignedFeedFailureExpirationInterval': 0, 'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True}}
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)

archive = server / 'update.zip'
subprocess.run(['ditto', '-c', '-k', '--norsrc', '--noextattr', '--noacl', '--keepParent',
    str(fixture / 'candidate/iMac Update Test.app'), str(archive)], check=True)
sign = [str(vendor / 'bin/sign_update'), '--ed-key-file', str(private)]
signature = subprocess.check_output(sign + ['-p', str(archive)], text=True).strip()
assert len(base64.b64decode(signature)) == 64
subprocess.run([str(fixture / 'VerifySignature'), public, str(archive), signature], check=True)
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'; ET.register_namespace('sparkle', ns)
rss = ET.Element('rss', {'version': '2.0'}); channel = ET.SubElement(rss, 'channel')
ET.SubElement(channel, 'title').text = 'Prueba local'
item = ET.SubElement(channel, 'item'); ET.SubElement(item, 'title').text = 'Prueba 0.0.2'
ET.SubElement(item, f'{{{ns}}}version').text = '2'
ET.SubElement(item, f'{{{ns}}}shortVersionString').text = '0.0.2'
ET.SubElement(item, f'{{{ns}}}minimumSystemVersion').text = '13.0'
ET.SubElement(item, 'description').text = '<p>Prueba aislada: confirmar actualización, sustituir la app y relanzar en 0.0.2.</p>'
ET.SubElement(item, 'enclosure', {'url': 'http://127.0.0.1:18777/update.zip', 'length': str(archive.stat().st_size),
    'type': 'application/octet-stream', f'{{{ns}}}edSignature': signature})
feed = server / 'appcast.xml'; ET.indent(rss)
ET.ElementTree(rss).write(feed, encoding='utf-8', xml_declaration=True)
subprocess.run(sign + ['-p', str(feed)], check=True)
subprocess.run(sign + ['--verify', str(feed)], check=True)
(root / '.build/last-update-fixture.txt').write_text(str(fixture))
print(f'Fixture lista: {fixture}')
print('Servir únicamente su carpeta server en 127.0.0.1:18777 y abrir installed/iMac Update Test.app.')
