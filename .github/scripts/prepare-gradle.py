"""Use the same pinned Gradle ZIP through GitHub's binary asset API in CI."""
import os
from pathlib import Path
from github_asset import download_asset

target = Path(os.environ['RUNNER_TEMP']) / 'gradle-8.14.3-all.zip'
expected = 'ed1a8d686605fd7c23bdf62c7fc7add1c5b23b2bbc3721e661934ef4a4911d7c'
download_asset('gradle/gradle-distributions', 269969098, expected, target)

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
