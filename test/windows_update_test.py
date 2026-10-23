"""Exercise the bundled installer against disposable bundles, never the installed app."""
import hashlib
import ctypes
from pathlib import Path
import subprocess
import sys
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

    def check(entries, expected_success, *, wrong_hash=False, validate=True, expected_error=None):
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
        if expected_error:
            assert expected_error in result.stderr, result.stderr
        assert original.read_bytes() == b'original executable fixture'
        assert (install / 'flutter_windows.dll').read_bytes() == b'original library fixture'
        assert not list(base.glob('stage-*')), 'staging directory was not cleaned'

    valid = {prefix + 'oplayer.exe': b'new invalid executable fixture',
             prefix + 'flutter_windows.dll': b'new library fixture',
             prefix + 'data/flutter_assets/test': b'new data fixture'}
    check(valid, True)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p]
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.ReleaseMutex.argtypes = [ctypes.c_void_p]
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    mutex_name = 'Local\\OPlayer.Update.' + hashlib.sha256(str(install).lower().encode()).hexdigest().upper()
    lock = kernel.CreateMutexW(None, True, mutex_name)
    assert lock
    try:
        check(valid, False, expected_error='An update is already running')
    finally:
        kernel.ReleaseMutex(lock)
        kernel.CloseHandle(lock)
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

    # The normal child process must survive its app parent exiting, replace the
    # bundle, and launch it. The fixture executable only writes a local marker.
    replacement = base / 'replacement.exe'
    compile_script = base / 'compile.ps1'
    compile_script.write_text('''param([string]$Output)
Add-Type -OutputAssembly $Output -OutputType WindowsApplication -TypeDefinition @'
public class Program {
  public static void Main(string[] args) {
    if (args.Length > 0) { System.Threading.Thread.Sleep(30000); return; }
    System.IO.File.WriteAllText(System.IO.Path.Combine(
      System.AppDomain.CurrentDomain.BaseDirectory, "started.txt"), "new");
  }
}
'@
''', encoding='ascii')
    subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-File',
                    str(compile_script), str(replacement)], check=True, capture_output=True, timeout=30)
    archive = base / 'success.zip'
    with zipfile.ZipFile(archive, 'w') as bundle:
        bundle.writestr(prefix + 'oplayer.exe', replacement.read_bytes())
        bundle.writestr(prefix + 'flutter_windows.dll', b'updated library')
        bundle.writestr(prefix + 'data/updated', b'updated data')
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    # A second running window must be detected before writing ready/copying.
    conflict = base / 'blocked.zip'
    conflict.write_bytes(archive.read_bytes())
    original.write_bytes(replacement.read_bytes())
    blocker = subprocess.Popen([str(original), 'hold'])
    try:
        result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive',
            '-ExecutionPolicy', 'Bypass', '-File', str(script), '-Archive', str(conflict),
            '-InstallDir', str(install), '-ExpectedHash', checksum, '-Version', '0.1.7-nightly.1',
            '-Architecture', architecture, '-AppProcessId', '2147483647'], capture_output=True, text=True, timeout=30)
        assert result.returncode != 0 and 'Another OPlayer instance' in result.stderr, result.stderr
        assert not Path(str(conflict) + '.ready').exists()
        assert original.read_bytes() == replacement.read_bytes()
    finally:
        blocker.terminate()
        blocker.wait(timeout=10)
        original.write_bytes(b'original executable fixture')
    parent = '''
import os, pathlib, subprocess, sys, time
script, archive, install, checksum, architecture = sys.argv[1:]
helper = subprocess.Popen(['powershell.exe', '-NoProfile', '-NonInteractive',
    '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', script,
    '-Archive', archive, '-InstallDir', install, '-ExpectedHash', checksum,
    '-Version', '0.1.7-nightly.1', '-Architecture', architecture,
    '-AppProcessId', str(os.getpid())], stdin=subprocess.PIPE,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
helper.stdin.close()
for _ in range(300):
    if pathlib.Path(archive + '.ready').exists():
        sys.exit(0)
    if helper.poll() is not None:
        raise RuntimeError(helper.stderr.read().decode(errors='replace'))
    time.sleep(.1)
helper.kill()
raise RuntimeError('installer did not become ready')
'''
    subprocess.run([sys.executable, '-c', parent, str(script), str(archive),
                    str(install), checksum, architecture], check=True, timeout=40)
    import time
    for _ in range(300):
        if Path(str(archive) + '.error').exists():
            break
        if (install / 'started.txt').exists() and not list(base.glob('stage-*')):
            break
        time.sleep(.1)
    failure = Path(str(archive) + '.error')
    assert not failure.exists(), failure.read_text(encoding='utf-8-sig') if failure.exists() else ''
    assert (install / 'started.txt').read_text() == 'new'
    assert original.read_bytes() == replacement.read_bytes()
    assert (install / 'flutter_windows.dll').read_bytes() == b'updated library'
    assert (install / 'data/updated').read_bytes() == b'updated data'
    assert not list(base.glob('stage-*')), 'successful staging was not cleaned'
print('Windows installer validation, rollback, parent exit and replacement checks passed')
