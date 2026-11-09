"""Download a pinned public release asset without credentials; reject changed bytes."""
import hashlib
from pathlib import Path
import urllib.request


def download_asset(repository, asset_id, expected, target):
    target = Path(target)
    if target.exists():
        with target.open('rb') as existing:
            if hashlib.file_digest(existing, 'sha256').hexdigest() == expected:
                return target
    target.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        f'https://api.github.com/repos/{repository}/releases/assets/{asset_id}',
        headers={'Accept': 'application/octet-stream', 'User-Agent': 'OPlayer-build'},
    )
    partial = target.with_suffix(target.suffix + '.part')
    try:
        digest = hashlib.sha256()
        with urllib.request.urlopen(request, timeout=60) as response, partial.open('wb') as output:
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                output.write(chunk)
        if digest.hexdigest() != expected:
            raise RuntimeError(f'SHA256 verification failed: {target.name}')
        partial.replace(target)
        return target
    finally:
        partial.unlink(missing_ok=True)
