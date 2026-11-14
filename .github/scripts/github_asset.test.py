import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from unittest.mock import patch
from github_asset import download_asset

with tempfile.TemporaryDirectory() as directory:
    target = Path(directory) / 'dependency.zip'
    data = b'pinned dependency'
    digest = hashlib.sha256(data).hexdigest()
    with patch('urllib.request.urlopen', return_value=io.BytesIO(data)) as request:
        assert download_asset('owner/repository', 123, digest, target) == target
        assert request.call_args.args[0].get_header('Accept') == 'application/octet-stream'
    with patch('urllib.request.urlopen', side_effect=AssertionError('valid cache must not download')):
        download_asset('owner/repository', 123, digest, target)
    target.write_bytes(b'invalid cache')
    with patch('urllib.request.urlopen', return_value=io.BytesIO(b'changed bytes')):
        try:
            download_asset('owner/repository', 123, digest, target)
            raise AssertionError('changed dependency accepted')
        except RuntimeError:
            pass
    assert target.read_bytes() == b'invalid cache'
    assert not target.with_suffix('.zip.part').exists()
    with patch.dict(os.environ, {'GITHUB_TOKEN': 'test-ci-token'}):
        with patch('urllib.request.urlopen', return_value=io.BytesIO(data)) as request:
            download_asset('owner/repository', 123, digest, target)
            api_request = request.call_args.args[0]
            assert api_request.get_header('Authorization') == 'Bearer test-ci-token'
            redirect = urllib.request.HTTPRedirectHandler().redirect_request(
                api_request, None, 302, 'Found', {}, 'https://release-assets.githubusercontent.com/dependency.zip')
            assert redirect.get_header('Authorization') is None
    legacy_target = Path(directory) / 'legacy-angle.7z'
    with patch('urllib.request.urlopen', return_value=io.BytesIO(data)):
        download_asset('owner/repository', 123, hashlib.md5(data).hexdigest(), legacy_target, 'md5')
    # Exercise CMake argument/path quoting through the real CLI, using verified
    # local files so this integration check never requires network or credentials.
    if cmake := shutil.which('cmake'):
        script = Path(directory) / 'cached asset check.cmake'
        helper = Path(__file__).with_name('github-asset.cmake').resolve().as_posix()
        script.write_text(
            f'include("{helper}")\n'
            f'oplayer_github_asset(owner/repository 123 {digest} "{target.as_posix()}")\n'
            f'oplayer_github_asset(owner/repository 123 {hashlib.md5(data).hexdigest()} '
            f'"{legacy_target.as_posix()}" md5)\n', encoding='utf-8')
        subprocess.run([cmake, f'-DPython3_EXECUTABLE={sys.executable}', '-P', str(script)], check=True)
print('Pinned asset verification, cache and partial cleanup checks passed')
