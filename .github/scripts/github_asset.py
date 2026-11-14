"""Download a pinned public release asset; use CI API auth and verify its bytes."""
import hashlib
import os
from pathlib import Path
import urllib.request


def download_asset(repository, asset_id, expected, target, algorithm='sha256'):
    target = Path(target)
    if target.exists():
        with target.open('rb') as existing:
            if hashlib.file_digest(existing, algorithm).hexdigest() == expected:
                return target
    target.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(
        f'https://api.github.com/repos/{repository}/releases/assets/{asset_id}',
        headers={'Accept': 'application/octet-stream', 'User-Agent': 'OPlayer-build'},
    )
    if token := os.environ.get('GITHUB_TOKEN'):
        # urllib does not copy unredirected headers to the signed asset URL.
        request.add_unredirected_header('Authorization', f'Bearer {token}')
    partial = target.with_suffix(target.suffix + '.part')
    try:
        digest = hashlib.new(algorithm)
        with urllib.request.urlopen(request, timeout=60) as response, partial.open('wb') as output:
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                output.write(chunk)
        if digest.hexdigest() != expected:
            raise RuntimeError(f'{algorithm.upper()} verification failed: {target.name}')
        partial.replace(target)
        return target
    finally:
        partial.unlink(missing_ok=True)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repository')
    parser.add_argument('asset_id', type=int)
    parser.add_argument('expected')
    parser.add_argument('target')
    parser.add_argument('--algorithm', choices=['sha256', 'md5'], default='sha256')
    args = parser.parse_args()
    download_asset(args.repository, args.asset_id, args.expected, args.target, args.algorithm)
