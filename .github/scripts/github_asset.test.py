import hashlib
import io
from pathlib import Path
import tempfile
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
print('Pinned asset verification, cache and partial cleanup checks passed')
