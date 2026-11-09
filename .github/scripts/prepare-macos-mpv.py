"""Prefetch the package's unchanged mpv archive and fail early if make fails."""
import json
from pathlib import Path
import subprocess
from urllib.parse import unquote, urljoin, urlparse
from github_asset import download_asset

config = Path('.dart_tool/package_config.json').resolve()
package = next(p for p in json.loads(config.read_text())['packages'] if p['name'] == 'media_kit_libs_macos_video')
root = Path(unquote(urlparse(urljoin(config.as_uri(), package['rootUri'])).path)) / 'macos'
expected = '84d2ad98e046e82c6dc34d8547d76c2afeaee89c0f53032773be8985c95536d6'
if expected not in (root / 'Makefile').read_text():
    raise RuntimeError('Unexpected macOS mpv dependency version')
download_asset('media-kit/libmpv-darwin-build', 127491789, expected,
               root / '.cache/xcframeworks/libmpv-xcframeworks-v0.6.0-macos-universal.tar.gz')
subprocess.run(['make'], cwd=root, check=True)
