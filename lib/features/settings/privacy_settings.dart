import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/mouse_nav.dart';
import '../../core/resource_locks.dart';
import '../../core/settings.dart';
import 'pattern_pad.dart';

Future<void> _showError(BuildContext context, Object error) async {
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
}

Future<bool> configureSharedLock(BuildContext context) async {
  final pattern = await showDialog<bool>(
    context: context,
    builder: (c) => SimpleDialog(
      title: const Text('공통 잠금 방식 선택'),
      children: [
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('등록한 PIN·패턴을 앱과 모든 잠긴 리소스에서 함께 사용합니다. 다른 방식의 등록 정보는 유지합니다.'),
        ),
        SimpleDialogOption(onPressed: () => Navigator.pop(c, false), child: const Text('PIN · 숫자 6자리')),
        SimpleDialogOption(onPressed: () => Navigator.pop(c, true), child: const Text('패턴 · 4개 이상의 점')),
      ],
    ),
  );
  if (pattern == null || !context.mounted) return false;
  if (!pattern) return _configurePin(context);
  return await showDialog<bool>(context: context, builder: (_) => const _PatternSetupDialog()) ?? false;
}

Future<bool> _configurePin(BuildContext context) async {
  final first = TextEditingController();
  final second = TextEditingController();
  final pin = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('공통 잠금 PIN 설정'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('숫자 6자리 PIN을 입력하세요. 잠금 정보를 잊으면 잠긴 항목을 앱에서 열 수 없습니다. 파일 자체를 암호화하는 기능은 아닙니다.'),
          TextField(
            controller: first,
            autofocus: true,
            obscureText: true,
            maxLength: 6,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'PIN'),
          ),
          TextField(
            controller: second,
            obscureText: true,
            maxLength: 6,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'PIN 확인'),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('취소')),
        TextButton(
          onPressed: () {
            if (first.text.length == 6 && first.text == second.text) {
              Navigator.pop(c, first.text);
            } else {
              _showError(context, '숫자 6자리 PIN을 두 칸에 동일하게 입력해 주세요');
            }
          },
          child: const Text('저장'),
        ),
      ],
    ),
  );
  // Dialog fields may still be used during their reverse transition.
  await Future<void>.delayed(const Duration(milliseconds: 250));
  first.dispose();
  second.dispose();
  if (pin == null) return false;
  try {
    await ResourceLocks.instance.setPin(pin);
    return true;
  } catch (error) {
    if (context.mounted) await _showError(context, error);
    return false;
  }
}

Future<void> toggleResourceLock(BuildContext context, String key, String title) async {
  final locks = ResourceLocks.instance;
  if (!locks.configured && !await configureSharedLock(context)) return;
  if (!context.mounted) return;
  try {
    await locks.toggle(key, title);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(locks.hasExact(key) ? '잠금 설정됨 · 앱 복귀 시 다시 인증합니다' : '잠금이 해제되었습니다')));
    }
  } catch (error) {
    if (context.mounted) await _showError(context, error);
  }
}

class ResourceUnlockPanel extends StatefulWidget {
  const ResourceUnlockPanel({super.key, required this.onUnlocked, this.forceCredential = false});
  final VoidCallback onUnlocked;
  final bool forceCredential;
  @override
  State<ResourceUnlockPanel> createState() => _ResourceUnlockPanelState();
}

class _ResourceUnlockPanelState extends State<ResourceUnlockPanel> with WidgetsBindingObserver {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _usePattern = false;
  bool _showCredential = true;
  bool _autoBiometricPending = false;
  bool get _prefersBiometric => ResourceLocks.supportsSystemAuthentication && ResourceLocks.instance.biometricEnabled;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _usePattern = !ResourceLocks.instance.hasPin && ResourceLocks.instance.hasPattern;
    _showCredential = !_prefersBiometric;
    _autoBiometricPending = _prefersBiometric;
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
  }

  void _tryBiometric() {
    if (!mounted || _busy || !_autoBiometricPending || ResourceLocks.instance.inBackground) return;
    _autoBiometricPending = false;
    _unlock(biometric: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.paused || state == AppLifecycleState.hidden) && _prefersBiometric) {
      setState(() {
        _autoBiometricPending = true;
        _showCredential = false;
      });
    }
    if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pin.dispose();
    super.dispose();
  }

  Future<void> _unlock({bool biometric = false, List<int>? pattern}) async {
    if (_busy) return;
    if (biometric) FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _busy = true;
      if (biometric) _showCredential = false;
      _error = null;
    });
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final locks = ResourceLocks.instance;
      final success = biometric
          ? await locks.biometric()
          : pattern != null
          ? await locks.verifyPattern(pattern)
          : await locks.verifyPin(_pin.text);
      if (!mounted) return;
      if (success) {
        widget.onUnlocked();
        return;
      }
      setState(() {
        if (biometric) _showCredential = !_autoBiometricPending;
        _error = locks.retrySeconds > 0 ? '${locks.retrySeconds}초 후 다시 입력해 주세요' : '인증하지 못했습니다';
        _pin.clear();
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          if (biometric) _showCredential = !_autoBiometricPending;
          _error = '인증 정보를 읽거나 저장하지 못했습니다';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.lock, size: 40),
        const SizedBox(height: 12),
        Text(
          widget.forceCredential
              ? '등록된 잠금 정보 확인'
              : ResourceLocks.instance.authenticatingResource != null
              ? '리소스 잠금 해제'
              : ResourceLocks.instance.appLockEnabled
              ? '앱 잠금 해제'
              : '리소스 잠금 해제',
          style: const TextStyle(fontSize: 20),
        ),
        if (ResourceLocks.instance.authenticatingResource case final String resource)
          Text(ResourceLocks.instance.resources[resource] ?? resource, maxLines: 2, overflow: TextOverflow.ellipsis),
        if (!_showCredential) ...[
          const SizedBox(height: 20),
          const Icon(Icons.fingerprint, size: 48),
          Text(Platform.isWindows ? 'Windows Hello로 확인 중…' : '지문·생체인증으로 확인 중…'),
        ],
        if (_showCredential && _usePattern)
          PatternPad(
            enabled: !_busy,
            onCompleted: (pattern) => _unlock(pattern: pattern),
          ),
        if (_showCredential && !_usePattern)
          TextField(
            controller: _pin,
            autofocus: true,
            obscureText: true,
            maxLength: 6,
            enabled: !_busy,
            enableInteractiveSelection: false,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: 'PIN', errorText: _error),
            onSubmitted: (_) => _unlock(),
          ),
        if (_showCredential && _usePattern && _error != null)
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 12),
                Text('잠금 정보 확인 중…'),
              ],
            ),
          ),
        if (_showCredential && !_usePattern)
          FilledButton(onPressed: _busy ? null : () => _unlock(), child: Text(_busy ? '확인 중…' : '잠금 해제')),
        if (_showCredential && ResourceLocks.instance.hasPattern && ResourceLocks.instance.hasPin)
          TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                    _usePattern = !_usePattern;
                    _error = null;
                  }),
            child: Text(_usePattern ? 'PIN으로 해제' : '패턴으로 해제'),
          ),
        if (_showCredential && _prefersBiometric)
          TextButton.icon(
            onPressed: _busy ? null : () => _unlock(biometric: true),
            icon: const Icon(Icons.fingerprint),
            label: Text(Platform.isWindows ? 'Windows Hello로 인증' : '지문·생체인증 사용'),
          ),
      ],
    ),
  );
}

class PrivacyShell extends StatefulWidget {
  const PrivacyShell({super.key, required this.child});
  final Widget child;
  @override
  State<PrivacyShell> createState() => _PrivacyShellState();
}

class _PrivacyShellState extends State<PrivacyShell> with WidgetsBindingObserver {
  final locks = ResourceLocks.instance;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    locks.onAuthenticate = _authenticate;
    locks.addListener(_syncPrivacy);
  }

  void _syncPrivacy() {
    locks.syncNativePrivacy().catchError((Object _) {
      // A failed native policy update must keep the app covered.
      if (!locks.unavailable) {
        locks.unavailable = true;
        locks.relock();
      }
    });
  }

  Future<bool> _authenticate(bool forceCredential) async {
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return false;
    final context = MouseNav.navigatorKey.currentContext;
    if (context == null || locks.shielded) return false;
    if (!context.mounted) return false;
    return await showDialog<bool>(
          context: context,
          builder: (c) => Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: ResourceUnlockPanel(forceCredential: forceCredential, onUnlocked: () => Navigator.pop(c, true)),
            ),
          ),
        ) ??
        false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) locks.background(true);
    if (state == AppLifecycleState.resumed) locks.background(false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    locks.onAuthenticate = null;
    locks.removeListener(_syncPrivacy);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: locks,
    builder: (_, __) => Stack(
      children: [
        ExcludeSemantics(
          excluding: locks.shielded,
          child: ExcludeFocus(
            excluding: locks.shielded,
            child: AbsorbPointer(absorbing: locks.shielded, child: widget.child),
          ),
        ),
        if (locks.shielded)
          Positioned.fill(
            child: Overlay(
              initialEntries: [
                OverlayEntry(
                  builder: (context) => Material(
                    color: Colors.black,
                    child: SafeArea(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
                        child: Center(
                          child: SingleChildScrollView(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 380),
                              child: locks.unavailable
                                  ? Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text('보안 저장소를 읽을 수 없습니다'),
                                        TextButton(onPressed: locks.init, child: const Text('다시 시도')),
                                      ],
                                    )
                                  : ResourceUnlockPanel(onUnlocked: () {}),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class PrivacySettings extends StatelessWidget {
  const PrivacySettings({super.key});
  @override
  Widget build(BuildContext context) {
    final locks = ResourceLocks.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([locks, AppSettings.instance]),
      builder: (_, __) => Column(
        children: [
          const ListTile(
            title: Text('개인정보 보호', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          if (ResourceLocks.supportsSystemAuthentication)
            SwitchListTile(
              title: const Text('캡처·화면 녹화 방지 (수동 설정)'),
              subtitle: Text(locks.appLockEnabled ? '앱 잠금을 끈 뒤 적용할 설정입니다. 현재는 앱 잠금으로 차단 중입니다.' : '앱 전체 화면에 적용'),
              value: AppSettings.instance.preventCapture,
              onChanged: (value) async {
                try {
                  await locks.setCaptureProtection(value);
                } catch (error) {
                  if (context.mounted) _showError(context, error);
                }
              },
            ),
          if (ResourceLocks.supportsSystemAuthentication)
            ListTile(
              dense: true,
              leading: Icon(
                locks.forcesCaptureProtection || AppSettings.instance.preventCapture
                    ? Icons.screen_lock_portrait
                    : Icons.screenshot,
              ),
              title: Text(
                locks.forcesCaptureProtection || AppSettings.instance.preventCapture
                    ? '현재 캡처 차단 중${locks.appLockEnabled ? ' · 앱 잠금으로 강제 적용' : ''}'
                    : '현재 캡처 허용',
              ),
            ),
          SwitchListTile(
            title: const Text('앱 잠금'),
            subtitle: const Text('앱 시작·백그라운드 복귀 시 인증 · 사용 중에는 캡처 방지 항상 적용'),
            value: locks.appLockEnabled,
            onChanged: (value) async {
              if (!locks.configured && !await configureSharedLock(context)) return;
              try {
                await locks.setAppLockEnabled(value);
              } catch (error) {
                if (context.mounted) _showError(context, error);
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(locks.configured ? '공통 잠금 정보 변경' : '공통 잠금 정보 등록'),
            subtitle: Text(
              locks.configured
                  ? '현재: ${[if (locks.hasPin) "PIN", if (locks.hasPattern) "패턴"].join(" · ")} · 앱과 모든 잠긴 리소스가 함께 사용'
                  : 'PIN 또는 패턴을 한 번 등록 · 앱과 모든 잠긴 리소스에 공통 적용',
            ),
            onTap: () => configureSharedLock(context),
          ),
          if (locks.hasPin)
            ListTile(
              leading: const Icon(Icons.pin_outlined),
              title: const Text('등록한 PIN 삭제'),
              subtitle: Text(locks.hasPattern ? '패턴과 생체인증은 유지됩니다' : '마지막 잠금 정보 · 보호 중인 잠금을 먼저 해제해야 삭제할 수 있습니다'),
              onTap: () async {
                try {
                  await locks.removePin();
                } catch (error) {
                  if (context.mounted) _showError(context, error);
                }
              },
            ),
          if (locks.hasPattern)
            ListTile(
              leading: const Icon(Icons.pattern),
              title: const Text('등록한 패턴 삭제'),
              subtitle: Text(locks.hasPin ? 'PIN과 생체인증은 유지됩니다' : '마지막 잠금 정보 · 보호 중인 잠금을 먼저 해제해야 삭제할 수 있습니다'),
              onTap: () async {
                try {
                  await locks.setPattern(null);
                } catch (error) {
                  if (context.mounted) _showError(context, error);
                }
              },
            ),
          if (ResourceLocks.supportsSystemAuthentication && locks.configured)
            SwitchListTile(
              title: Text(Platform.isWindows ? 'Windows Hello로 잠금 해제' : '지문·생체인증으로 잠금 해제'),
              subtitle: Text(
                Platform.isWindows ? 'Windows에 등록한 얼굴·지문·Hello PIN으로 인증' : '휴대폰에 등록한 지문·생체정보로 앱과 리소스 잠금 해제',
              ),
              value: locks.biometricEnabled,
              onChanged: (value) async {
                try {
                  await locks.setBiometric(value);
                } catch (error) {
                  if (context.mounted) _showError(context, error);
                }
              },
            ),
          if (locks.appLockEnabled || locks.resources.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.lock),
              title: const Text('지금 다시 잠그기'),
              subtitle: Text('보호 중인 항목 ${locks.resources.length}개 · 백그라운드 복귀 시 앱에서 재인증'),
              onTap: locks.relock,
            ),
          for (final entry in locks.resources.entries)
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Text(entry.value, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(entry.key, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.lock_open),
                tooltip: '잠금 설정 해제',
                onPressed: () => toggleResourceLock(context, entry.key, entry.value),
              ),
            ),
        ],
      ),
    );
  }
}

class _PatternSetupDialog extends StatefulWidget {
  const _PatternSetupDialog();
  @override
  State<_PatternSetupDialog> createState() => _PatternSetupDialogState();
}

class _PatternSetupDialogState extends State<_PatternSetupDialog> {
  List<int>? _first;
  int _generation = 0;
  bool _busy = false;
  String? _error;
  Future<void> _complete(List<int> pattern) async {
    if (_busy) return;
    if (!ResourceLocks.validPattern(pattern)) {
      setState(() => _error = '서로 다른 점을 4개 이상 연결해 주세요');
      return;
    }
    if (_first == null) {
      setState(() {
        _first = List.of(pattern);
        _generation++;
        _error = null;
      });
      return;
    }
    if (_first!.join(',') != pattern.join(',')) {
      setState(() => _error = '패턴이 다릅니다. 확인 패턴을 다시 그려 주세요');
      return;
    }
    setState(() => _busy = true);
    try {
      await ResourceLocks.instance.setPattern(pattern);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => _error = '기존 잠금 정보 확인 또는 패턴 저장에 실패했습니다');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_first == null ? '새 패턴을 그려 주세요' : '같은 패턴을 한 번 더 그려 주세요'),
    content: SizedBox(
      width: 300,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('4개 이상의 점을 연결하세요. 앱과 모든 잠긴 리소스에서 공통으로 사용합니다.'),
            PatternPad(key: ValueKey(_generation), enabled: !_busy, onCompleted: _complete),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy
            ? null
            : () => setState(() {
                _first = null;
                _generation++;
                _error = null;
              }),
        child: const Text('다시 그리기'),
      ),
      TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('취소')),
    ],
  );
}
