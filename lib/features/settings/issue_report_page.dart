import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/diagnostic_report.dart';

class IssueReportPage extends StatefulWidget {
  const IssueReportPage({super.key, this.orientation});
  final Map<String, dynamic>? orientation;

  @override
  State<IssueReportPage> createState() => _IssueReportPageState();
}

class _IssueReportPageState extends State<IssueReportPage> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _steps = TextEditingController();
  String? _diagnostics;
  bool _include = true;
  bool _sending = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    if (widget.orientation != null) _title.text = '화면 회전 문제';
    DiagnosticReport.collect(orientation: widget.orientation).then((value) {
      if (mounted) setState(() => _diagnostics = value);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _steps.dispose();
    super.dispose();
  }

  String get _body =>
      DiagnosticReport.body(_description.text, _steps.text, diagnostics: _include ? _diagnostics : null);

  Future<void> _openIssue() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _sending = true;
      _message = null;
    });
    try {
      var uri = DiagnosticReport.issueUrl(_title.text, body: _body);
      // Avoid GitHub/browser URI limits without dropping report information.
      if (uri.toString().length > 7000) {
        await Clipboard.setData(ClipboardData(text: _body));
        uri = DiagnosticReport.issueUrl(_title.text);
        if (!mounted) return;
        setState(() => _message = '본문이 길어 클립보드에 복사했습니다. GitHub 이슈 본문에 붙여넣어 주세요.');
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('본문 복사 완료'),
            content: Text(_message!),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('GitHub 열기')),
            ],
          ),
        );
        if (proceed != true) return;
      }
      if (!mounted) return;
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) throw StateError('open failed');
    } catch (_) {
      if (mounted) setState(() => _message = 'GitHub를 열지 못했습니다. 본문을 복사해 github.com/gaeco0/OPlayer/issues에 등록해 주세요.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('진단 정보 보내기')),
    body: Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('접수처: gaeco0/OPlayer · GitHub Issues\n공개 이슈로 등록됩니다. GitHub 계정으로 로그인한 뒤 내용을 검토하고 최종 등록해 주세요.'),
          const SizedBox(height: 16),
          TextFormField(
            controller: _title,
            maxLength: 120,
            decoration: const InputDecoration(labelText: '제목'),
            validator: (v) => v == null || v.trim().isEmpty ? '제목을 입력해 주세요' : null,
          ),
          TextFormField(
            controller: _description,
            minLines: 3,
            maxLines: 6,
            maxLength: 10000,
            decoration: const InputDecoration(labelText: '발생한 증상'),
            validator: (v) => v == null || v.trim().isEmpty ? '증상을 입력해 주세요' : null,
          ),
          TextFormField(
            controller: _steps,
            minLines: 2,
            maxLines: 5,
            maxLength: 10000,
            decoration: const InputDecoration(labelText: '재현 방법 (선택)'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('진단 정보 포함'),
            subtitle: const Text('앱·OS 버전, 화면 상태, 네트워크 기능 켜짐 여부'),
            value: _include,
            onChanged: _sending ? null : (value) => setState(() => _include = value),
          ),
          const Text('자동 수집 정보에는 파일명·경로·방문 URL·계정·토큰을 넣지 않습니다. 직접 입력한 내용에도 개인정보가 없는지 확인해 주세요.'),
          if (_include) ...[
            const SizedBox(height: 12),
            if (_diagnostics == null)
              const LinearProgressIndicator()
            else
              ExpansionTile(title: const Text('진단 정보 미리보기'), children: [SelectableText(_diagnostics!)]),
          ],
          if (_message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_message!)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _sending || (_include && _diagnostics == null) ? null : _openIssue,
            icon: const Icon(Icons.open_in_new),
            label: const Text('GitHub 이슈 작성'),
          ),
          TextButton(
            onPressed: _sending || (_include && _diagnostics == null)
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _body));
                    if (mounted) setState(() => _message = '이슈 본문을 복사했습니다.');
                  },
            child: const Text('이슈 본문 복사'),
          ),
        ],
      ),
    ),
  );
}
