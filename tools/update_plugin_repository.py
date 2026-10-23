"""Regenerate the public extension catalog after editing bundled scripts."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1] / 'plugins'
plugins = []
for script in sorted(root.glob('*.js')):
    script.write_bytes(script.read_bytes().replace(b'\r\n', b'\n'))
    manifest = json.loads(script.read_text(encoding='utf-8').splitlines()[0][12:])
    if manifest['kind'] not in ('player', 'browser', 'resource') or not manifest.get('capabilities'):
        raise ValueError(f'{script.name}: declare a supported kind and capabilities')
    plugins.append({
        'id': manifest['id'], 'name': manifest['name'], 'version': manifest['version'],
        'kind': manifest['kind'], 'capabilities': manifest['capabilities'], 'pluginApi': manifest['api'], 'author': 'OPlayer',
        'features': manifest.get('features', ['브라우저 기능', '미디어 감지·주소 보완·광고 차단'] if manifest['kind'] == 'browser' else ['영상 필터'] if 'videoFilter' in manifest['capabilities'] else ['자막 검색', '자동 자막 적용'] if 'subtitles' in manifest['capabilities'] else ['클라우드 연결', '폴더 탐색', '미디어 재생']),
        'description': manifest.get('description', f"{manifest['name']} 사이트 기능" if manifest['kind'] == 'browser' else '영상 색상·회전·반전 설정 프리셋' if 'videoFilter' in manifest['capabilities'] else f"{manifest['name']} 자막 검색·다운로드·적용" if 'subtitles' in manifest['capabilities'] else f"{manifest['name']} 계정 연결·폴더 탐색·미디어 재생"),
        'downloadUrl': f'https://raw.githubusercontent.com/gaeco0/OPlayer/main/plugins/{script.name}',
        'sha256': hashlib.sha256(script.read_bytes()).hexdigest(),
        'homepage': 'https://github.com/gaeco0/OPlayer/tree/main/plugins',
    })
(root / 'repository.json').write_text(json.dumps({'api': 1, 'name': 'OPlayer 공식 확장앱 저장소',
    'description': 'OPlayer의 플레이어·브라우저·리소스 확장앱을 제공합니다.', 'plugins': plugins}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
