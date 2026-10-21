"""Regenerate the public extension catalog after editing bundled cloud scripts."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1] / 'plugins'
plugins = []
for script in sorted(root.glob('cloud.*.js')):
    script.write_bytes(script.read_bytes().replace(b'\r\n', b'\n'))
    manifest = json.loads(script.read_text(encoding='utf-8').splitlines()[0][12:])
    plugins.append({
        'id': manifest['id'], 'name': manifest['name'], 'version': manifest['version'],
        'kind': 'cloud', 'author': 'OPlayer',
        'features': ['클라우드 연결', '폴더 탐색', '미디어 재생'],
        'description': f"{manifest['name']} 계정 연결·폴더 탐색·미디어 재생",
        'downloadUrl': f'https://raw.githubusercontent.com/gaeco0/OPlayer/main/plugins/{script.name}',
        'sha256': hashlib.sha256(script.read_bytes()).hexdigest(),
        'homepage': 'https://github.com/gaeco0/OPlayer/tree/main/plugins',
    })
(root / 'repository.json').write_text(json.dumps({'api': 1, 'name': 'OPlayer 공식 확장앱 저장소',
    'description': 'OPlayer의 클라우드 연결 확장앱을 제공합니다.', 'plugins': plugins}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
