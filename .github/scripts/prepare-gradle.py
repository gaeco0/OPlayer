"""Use the same pinned Gradle ZIP through GitHub's binary asset API in CI."""
import hashlib
import os
from pathlib import Path
import urllib.request

target = Path(os.environ['RUNNER_TEMP']) / 'gradle-8.14.3-all.zip'
expected = 'ed1a8d686605fd7c23bdf62c7fc7add1c5b23b2bbc3721e661934ef4a4911d7c'
request = urllib.request.Request(
    'https://api.github.com/repos/gradle/gradle-distributions/releases/assets/269969098',
    headers={'Accept': 'application/octet-stream', 'User-Agent': 'OPlayer-build'},
)
partial = target.with_suffix('.zip.part')
try:
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=60) as response, partial.open('wb') as output:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
            output.write(chunk)
    if digest.hexdigest() != expected:
        raise RuntimeError('Gradle SHA256 verification failed')
    partial.replace(target)
finally:
    partial.unlink(missing_ok=True)

properties = Path('android/gradle/wrapper/gradle-wrapper.properties')
text = properties.read_text(encoding='utf-8')
original = r'distributionUrl=https\://services.gradle.org/distributions/gradle-8.14.3-all.zip'
if original not in text:
    raise RuntimeError('Unexpected Gradle distribution version')
properties.write_text(
    text.replace(original, 'distributionUrl=' + target.resolve().as_uri())
    + '\ndistributionSha256Sum=' + expected + '\n', encoding='utf-8',
)
print('Prepared SHA256-verified Gradle 8.14.3 for CI')
