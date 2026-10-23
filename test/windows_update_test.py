"""Exercise the bundled installer against disposable bundles, never the installed app."""
import hashlib
from pathlib import Path
import subprocess
import tempfile
import zipfile

script = Path(__file__).resolve().parents[1] / 'assets/update/install-windows.ps1'
with tempfile.TemporaryDirectory(prefix='oplayer-installer-') as temporary:
    base = Path(temporary).resolve()
    install = base / 'app'
    install.mkdir()
    original = install / 'oplayer.exe'
    original.write_bytes(b'original executable fixture')
    (install / 'flutter_windows.dll').write_bytes(b'original library fixture')
    prefix = 'OPlayer-0.1.7-nightly.1-windows-x64/'
    architecture = 'x64'

    def check(entries, expected_success, *, wrong_hash=False, validate=True):
        archive = base / 'update.zip'
        with zipfile.ZipFile(archive, 'w') as bundle:
            for name, body in entries.items():
                bundle.writestr(name, body)
        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        command = ['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                   '-File', str(script), '-Archive', str(archive), '-InstallDir', str(install),
                   '-AppProcessId', '2147483647', '-ExpectedHash', '0' * 64 if wrong_hash else checksum,
                   '-Version', '0.1.7-nightly.1', '-Architecture', architecture]
        if validate:
            command.append('-ValidateOnly')
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        assert (result.returncode == 0) == expected_success, result.stdout + result.stderr
        assert original.read_bytes() == b'original executable fixture'
        assert (install / 'flutter_windows.dll').read_bytes() == b'original library fixture'
        assert not list(base.glob('stage-*')), 'staging directory was not cleaned'

    valid = {prefix + 'oplayer.exe': b'new invalid executable fixture',
             prefix + 'flutter_windows.dll': b'new library fixture',
             prefix + 'data/flutter_assets/test': b'new data fixture'}
    check(valid, True)
    check(valid, False, wrong_hash=True)
    check({**valid, prefix + '../escape': b'bad'}, False)
    check({**valid, prefix + 'data/../../escape': b'bad'}, False)
    check({prefix + 'oplayer.exe': b'incomplete'}, False)
    # Starting the deliberately invalid replacement fails, so every replaced/new file must roll back.
    check(valid, False, validate=False)
    assert not (install / 'data/flutter_assets/test').exists()
    architecture = 'arm64'
    prefix = 'OPlayer-0.1.7-nightly.1-windows-arm64/'
    valid = {prefix + 'oplayer.exe': b'new invalid executable fixture',
             prefix + 'flutter_windows.dll': b'new library fixture',
             prefix + 'data/flutter_assets/test': b'new data fixture'}
    check(valid, True)
    check(valid, False, validate=False)
print('Windows installer checksum, traversal, bundle and rollback checks passed')
