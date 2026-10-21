import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/secure_store.dart';
import '../../sources/sftp_source.dart';

import '../../sources/server_store.dart';
import '../../sources/source_registry.dart';

/// 서버 추가/편집 (nPlayer "서버 추가" 화면)
Future<ServerConfig?> showServerEditDialog(BuildContext context, {ServerConfig? existing, ServerType? type}) {
  return showDialog<ServerConfig>(
    context: context,
    builder: (_) => _ServerEditDialog(existing: existing, initialType: type ?? existing?.type ?? ServerType.smb),
  );
}

class _ServerEditDialog extends StatefulWidget {
  const _ServerEditDialog({this.existing, required this.initialType});
  final ServerConfig? existing;
  final ServerType initialType;

  @override
  State<_ServerEditDialog> createState() => _ServerEditDialogState();
}

class _ServerEditDialogState extends State<_ServerEditDialog> {
  late ServerType _type = widget.initialType;
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _host = TextEditingController(text: widget.existing?.host);
  late final _port = TextEditingController(text: widget.existing?.port?.toString());
  late final _path = TextEditingController(text: widget.existing?.path ?? '/');
  late final _user = TextEditingController(text: widget.existing?.username);
  late final _domain = TextEditingController(text: widget.existing?.domain);
  final _pass = TextEditingController();
  late bool _secure = widget.existing?.secure ?? false;
  late bool _useKey = widget.existing?.useKey ?? false;
  final _keyText = TextEditingController();
  bool _anonymous = false;
  bool _obscure = true;
  bool _saving = false;
  String? _error;
  ServerConfig? _saved;

  @override
  void initState() {
    super.initState();
    _anonymous = widget.existing != null && widget.existing!.username.isEmpty;
    if (widget.existing != null) {
      ServerStore.instance.password(widget.existing!).then((v) {
        if (mounted) _pass.text = v;
      });
      SecureStore.instance.read(SftpSource.keyStorageKey(widget.existing!.id)).then((v) {
        if (mounted && v != null) _keyText.text = v;
      });
    }
  }

  Future<void> _save() async {
    var host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '주소를 입력하세요');
      return;
    }
    // "smb://192.168.0.2/share" 같은 입력 허용
    final parsed = Uri.tryParse(host.contains('://') ? host : 'x://$host');
    var path = _path.text.trim();
    if (parsed != null && parsed.host.isNotEmpty) {
      host = parsed.host;
      if (parsed.hasPort && _port.text.isEmpty) _port.text = '${parsed.port}';
      if (parsed.path.length > 1 && (path.isEmpty || path == '/')) path = parsed.path;
      if (parsed.scheme == 'https' || parsed.scheme == 'davs') _secure = true;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final isSftp = _type == ServerType.sftp;
    if (isSftp && _user.text.trim().isEmpty) {
      setState(() {
        _saving = false;
        _error = 'SFTP는 사용자 이름이 필요합니다';
      });
      return;
    }
    final cfg = ServerConfig(
      id: widget.existing?.id ?? ServerStore.newId(),
      type: _type,
      name: _name.text.trim().isEmpty ? host : _name.text.trim(),
      host: host,
      port: int.tryParse(_port.text.trim()),
      path: path.isEmpty ? '/' : path,
      username: (_anonymous && !isSftp) ? '' : _user.text.trim(),
      domain: _domain.text.trim(),
      secure: _secure,
      useKey: isSftp && _useKey,
    );
    if (isSftp && _useKey) {
      await SecureStore.instance.write(SftpSource.keyStorageKey(cfg.id), _keyText.text.trim());
    }
    await ServerStore.instance.saveServer(cfg, password: (_anonymous && !isSftp) ? '' : _pass.text);
    _saved = cfg;
    await SourceRegistry.instance.invalidate(cfg.id);

    // 연결 테스트
    try {
      final src = await SourceRegistry.instance.forServer(cfg);
      await src.list(src.rootPath).timeout(const Duration(seconds: 15));
      if (mounted) Navigator.pop(context, cfg);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = '연결 실패: $e\n(저장은 되었습니다)';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSftp = _type == ServerType.sftp;
    final showSecure = _type == ServerType.ftp || _type == ServerType.webdav;
    final anonymous = _anonymous && !isSftp;
    return AlertDialog(
      title: Text(widget.existing == null ? '서버 추가' : '서버 편집'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<ServerType>(
              segments: const [
                ButtonSegment(value: ServerType.smb, label: Text('SMB')),
                ButtonSegment(value: ServerType.ftp, label: Text('FTP')),
                ButtonSegment(value: ServerType.sftp, label: Text('SFTP')),
                ButtonSegment(value: ServerType.webdav, label: Text('WebDAV')),
              ],
              selected: {_type},
              onSelectionChanged: widget.existing != null ? null : (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 12),
            TextField(controller: _name, decoration: const InputDecoration(labelText: '표시 이름 (선택)')),
            TextField(
              controller: _host,
              decoration: InputDecoration(
                labelText: '주소',
                hintText: _type == ServerType.webdav ? 'nas.local 또는 https://...' : '192.168.0.10',
              ),
            ),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: '포트', hintText: '${_type.defaultPort(_secure)}'),
                  enabled: _type != ServerType.smb,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _path,
                  decoration: InputDecoration(
                    labelText: _type == ServerType.smb ? '공유 폴더 (선택)' : '경로',
                    hintText: _type == ServerType.smb ? '/video' : '/',
                  ),
                ),
              ),
            ]),
            if (showSecure)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_type == ServerType.ftp ? 'FTPS (암호화)' : 'HTTPS'),
                value: _secure,
                onChanged: (v) => setState(() => _secure = v),
              ),
            if (!isSftp)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_type == ServerType.smb ? '게스트 접속' : '익명 접속'),
                value: _anonymous,
                onChanged: (v) => setState(() => _anonymous = v),
              ),
            if (isSftp)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('개인 키로 인증'),
                subtitle: const Text('키에 암호가 있으면 아래 비밀번호 칸에 입력', style: TextStyle(fontSize: 12)),
                value: _useKey,
                onChanged: (v) => setState(() => _useKey = v),
              ),
            if (!anonymous) ...[
              TextField(controller: _user, decoration: const InputDecoration(labelText: '사용자 이름')),
              TextField(
                controller: _pass,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: (isSftp && _useKey) ? '키 암호 (없으면 비움)' : '비밀번호',
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
              if (_type == ServerType.smb)
                TextField(controller: _domain, decoration: const InputDecoration(labelText: '도메인 (보통 비움)')),
            ],
            if (isSftp && _useKey) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _keyText,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                decoration: InputDecoration(
                  labelText: '개인 키 (OpenSSH / PEM)',
                  hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: '키 파일 불러오기',
                    icon: const Icon(Icons.file_open_outlined),
                    onPressed: () async {
                      final r = await FilePicker.pickFiles(dialogTitle: '개인 키 파일 (id_ed25519, id_rsa …)');
                      final path = r?.files.single.path;
                      if (path != null) _keyText.text = await File(path).readAsString();
                    },
                  ),
                ),
              ),
            ],
            if (isSftp && widget.existing != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.key_off_outlined, size: 18),
                  label: const Text('호스트 키 초기화'),
                  onPressed: () async {
                    await SftpSource.forgetHostKey(widget.existing!.id);
                    if (mounted) setState(() => _error = '저장된 호스트 키를 지웠습니다. 다음 연결 때 새로 저장됩니다.');
                  },
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('취소')),
        if (_error != null && !_saving)
          TextButton(
            onPressed: () => Navigator.pop(context, _saved),
            child: const Text('그래도 닫기'),
          ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('저장 · 연결'),
        ),
      ],
    );
  }
}
