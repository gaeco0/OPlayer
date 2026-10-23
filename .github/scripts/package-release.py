"""Package complete Flutter bundles; never include signing credentials."""
import re
import shutil
import subprocess
import sys
from pathlib import Path

platform = sys.argv[1]
version = re.search(r'^version:\s*([^+\s]+)', Path('pubspec.yaml').read_text(encoding='utf-8'), re.M)[1]
output = Path('release-assets')
output.mkdir(exist_ok=True)
if platform in ('mobile', 'tv'):
    apks = sorted(Path('build/app/outputs/flutter-apk').glob(f'app-*-{platform}-release.apk'))
    if len(apks) != 3:
        raise SystemExit(f'Expected three signed {platform} APKs, found {len(apks)}')
    for apk in apks:
        abi = apk.name.removeprefix('app-').removesuffix(f'-{platform}-release.apk')
        shutil.copy2(apk, output / f'OPlayer-{version}-android-{platform}-{abi}.apk')
else:
    name = f'OPlayer-{version}-{platform}'
    stage = Path('.dart_tool/release-packages') / name
    stage.mkdir(parents=True, exist_ok=True)
    if platform in ('windows-x64', 'windows-arm64'):
        architecture = platform.split('-')[1]
        shutil.copytree(f'build/windows/{architecture}/runner/Release', stage, dirs_exist_ok=True)
    elif platform in ('linux-x64', 'linux-arm64'):
        architecture = platform.split('-')[1]
        shutil.copytree(f'build/linux/{architecture}/release/bundle', stage, dirs_exist_ok=True, symlinks=True)
    elif platform == 'macos-arm64':
        apps = list(Path('build/macos/Build/Products/Release').glob('*.app'))
        if len(apps) != 1:
            raise SystemExit('Expected one macOS app bundle')
        # ditto retains framework symlinks and signing metadata.
        subprocess.run(['ditto', str(apps[0]), str(stage / apps[0].name)], check=True)
    else:
        raise SystemExit(f'Unknown platform: {platform}')
    for file in ('LICENSE', 'README.md'):
        shutil.copy2(file, stage)
    for file in Path('third_party').rglob('*'):
        if file.is_file() and file.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
            destination = stage / file
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, destination)
    if platform == 'macos-arm64':
        subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(stage), str(output / f'{name}.zip')], check=True)
    else:
        shutil.make_archive(str(output / name), 'gztar' if platform.startswith('linux-') else 'zip', stage.parent, stage.name)
