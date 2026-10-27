"""Verifica los ZIPs tal como los recibirá el usuario, conservando symlinks."""
import json
import plistlib
import subprocess
import tempfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
config = json.loads((root / 'Config/release.json').read_text())
with tempfile.TemporaryDirectory(dir=root / '.build') as temporary:
    for role, filename, architectures in [
        ('Sender', 'iMac-Sender-AppleSilicon.zip', ['arm64']),
        ('Receiver', 'iMac-Receiver-universal.zip', ['arm64', 'x86_64']),
    ]:
        archive = root / 'dist' / filename
        with zipfile.ZipFile(archive) as zipped:
            assert zipped.testzip() is None
            assert all(not p.startswith('/') and '..' not in Path(p).parts and '__MACOSX' not in p for p in zipped.namelist())
        subprocess.run(['ditto', '-x', '-k', str(archive), temporary], check=True)
        bundle = Path(temporary) / f'iMac {role}.app'
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleVersion'] == str(config['build'])
        assert info['CFBundleShortVersionString'] == config['version']
        assert info['CFBundleIdentifier'] == f'local.imac-second-display.{role.lower()}'
        assert info['SUPublicEDKey'] == config['updatePublicKey']
        assert info['SUFeedURL'] == f'https://raw.githubusercontent.com/AlexandroHernandez27/imac-second-display/main/updates/{role.lower()}.xml'
        for setting in ('SUAllowsAutomaticUpdates', 'SUAutomaticallyUpdate', 'SUEnableSystemProfiling'):
            assert info[setting] is False, setting
        for setting in ('SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction'):
            assert info[setting] is True, setting
        assert info['SUSignedFeedFailureExpirationInterval'] == 0
        assert 'NSAppTransportSecurity' not in info  # Ninguna excepción HTTP de la fixture.
        framework = bundle / 'Contents/Frameworks/Sparkle.framework'
        assert (framework / 'Versions/Current').is_symlink()
        assert (bundle / 'Contents/Resources/Sparkle-LICENSE.txt').is_file()
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
        subprocess.run(['lipo', str(bundle / f'Contents/MacOS/iMac{role}'), '-verify_arch', *architectures], check=True)
        subprocess.run(['lipo', str(framework / 'Sparkle'), '-verify_arch', *architectures], check=True)
        print(f'PASS: ZIP {role}, firmas, arquitectura, versión y actualización siempre con confirmación.')
