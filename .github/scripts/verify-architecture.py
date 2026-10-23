"""Reject mislabeled desktop bundles, including DLL/SO architecture mismatches."""
from pathlib import Path
import struct
import sys


def machine(file):
    with file.open('rb') as source:
        header = source.read(64)
        if header[:2] == b'MZ':
            source.seek(struct.unpack_from('<I', header, 60)[0])
            signature = source.read(6)
            if signature[:4] != b'PE\0\0':
                raise ValueError(f'Invalid PE file: {file}')
            return ('pe', struct.unpack_from('<H', signature, 4)[0])
        if header[:4] == b'\x7fELF' and header[4] == 2:
            return ('elf', struct.unpack_from('<H' if header[5] == 1 else '>H', header, 18)[0])
    raise ValueError(f'Unsupported native binary: {file}')


def verify(target):
    os_name, arch = target.split('-')
    if os_name == 'windows':
        root = Path(f'build/windows/{arch}/runner/Release')
        files = [root / 'oplayer.exe', *root.glob('*.dll')]
        expected = ('pe', {'x64': 0x8664, 'arm64': 0xaa64}[arch])
    elif os_name == 'linux':
        root = Path(f'build/linux/{arch}/release/bundle')
        files = [root / 'oplayer', *root.rglob('*.so'), *root.rglob('*.so.*')]
        expected = ('elf', {'x64': 62, 'arm64': 183}[arch])
    else:
        raise ValueError(f'Unsupported target: {target}')
    for file in files:
        actual = machine(file)
        if actual != expected:
            raise ValueError(f'{file}: architecture {actual} does not match {target}')
    print(f'{target}: verified {len(files)} native binaries')


if __name__ == '__main__':
    verify(sys.argv[1])
