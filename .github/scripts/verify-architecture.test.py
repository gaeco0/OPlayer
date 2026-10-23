import importlib.util
from pathlib import Path
import struct
import tempfile

spec = importlib.util.spec_from_file_location('verify_architecture', Path(__file__).with_name('verify-architecture.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as directory:
    file = Path(directory) / 'native'
    for machine, expected in [(0x8664, 'x64'), (0xaa64, 'arm64')]:
        data = bytearray(128)
        data[:2] = b'MZ'
        struct.pack_into('<I', data, 60, 64)
        data[64:68] = b'PE\0\0'
        struct.pack_into('<H', data, 68, machine)
        file.write_bytes(data)
        assert module.machine(file) == ('pe', machine), expected
    for machine in (62, 183):
        data = bytearray(64)
        data[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<H', data, 18, machine)
        file.write_bytes(data)
        assert module.machine(file) == ('elf', machine)
    file.write_bytes(b'not a native binary')
    try:
        module.machine(file)
        raise AssertionError('Invalid binary accepted')
    except ValueError:
        pass
print('Desktop native architecture checks passed')
