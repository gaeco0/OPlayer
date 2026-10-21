"""Check Flutter's flavored APK names and UTF-8 pubspec on every runner."""
import subprocess
import sys
import tempfile
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
print('APK packaging checks passed')
