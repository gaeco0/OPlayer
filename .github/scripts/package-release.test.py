"""Check Flutter's flavored APK names and UTF-8 pubspec on every runner."""
import subprocess
import sys
import tempfile
import zipfile
import tarfile
from pathlib import Path

script = Path(__file__).with_name('package-release.py').resolve()
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / 'pubspec.yaml').write_text('version: 0.1.0+2\n# 플레이어\n', encoding='utf-8')
    apks = root / 'build/app/outputs/flutter-apk'
    apks.mkdir(parents=True)
    expected = set()
    for flavor in ('mobile', 'tv'):
        for abi in ('arm64-v8a', 'armeabi-v7a', 'x86_64'):
            (apks / f'app-{abi}-{flavor}-release.apk').write_bytes(b'fixture')
            expected.add(f'OPlayer-0.1.0-android-{flavor}-{abi}.apk')
        subprocess.run([sys.executable, str(script), flavor], cwd=root, check=True)
    assert {file.name for file in (root / 'release-assets').iterdir()} == expected
    (root / 'LICENSE').write_text('License fixture')
    (root / 'README.md').write_text('Readme fixture')
    for os_name in ('windows', 'linux'):
        for architecture in ('x64', 'arm64'):
            target = f'{os_name}-{architecture}'
            bundle = root / f'build/{os_name}/{architecture}' / ('runner/Release' if os_name == 'windows' else 'release/bundle')
            bundle.mkdir(parents=True)
            executable = 'oplayer.exe' if os_name == 'windows' else 'oplayer'
            payload = target.encode()
            (bundle / executable).write_bytes(payload)
            subprocess.run([sys.executable, str(script), target], cwd=root, check=True)
            prefix = f'OPlayer-0.1.0-{target}'
            if os_name == 'windows':
                with zipfile.ZipFile(root / f'release-assets/{prefix}.zip') as archive:
                    assert archive.read(f'{prefix}/{executable}') == payload
            else:
                with tarfile.open(root / f'release-assets/{prefix}.tar.gz') as archive:
                    assert archive.extractfile(f'{prefix}/{executable}').read() == payload
print('APK packaging checks passed')
