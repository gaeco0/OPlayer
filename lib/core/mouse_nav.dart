import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 마우스 뒤로/앞으로 버튼(XButton1/2)과 Alt+←/→ 를 앱 전체에서 처리한다.
///  · 뒤로: 최상위 Navigator.maybePop() → 열린 다이얼로그/시트/드로어 닫기,
///    각 화면의 PopScope(폴더 상위로, 웹 뒤로, 플레이어 패널 닫기/나가기)가 처리
///  · 앞으로: 등록된 핸들러(웹 브라우저의 goForward 등)가 있으면 호출
class MouseNav {
  MouseNav._();

  static final navigatorKey = GlobalKey<NavigatorState>();
  static final _forwardHandlers = <bool Function()>[];

  /// 앞으로 버튼 처리기 등록 (true를 반환하면 처리 완료). 가장 나중에 등록된 것이 우선.
  static void addForwardHandler(bool Function() h) => _forwardHandlers.add(h);
  static void removeForwardHandler(bool Function() h) => _forwardHandlers.remove(h);

  static void back() => navigatorKey.currentState?.maybePop();

  static void forward() {
    for (final h in _forwardHandlers.reversed) {
      if (h()) return;
    }
  }

  static bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final alt = HardwareKeyboard.instance.isAltPressed;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.browserBack || (alt && k == LogicalKeyboardKey.arrowLeft)) {
      back();
      return true;
    }
    if (k == LogicalKeyboardKey.browserForward || (alt && k == LogicalKeyboardKey.arrowRight)) {
      forward();
      return true;
    }
    return false;
  }

  static void installKeyHandler() => HardwareKeyboard.instance.addHandler(_onKey);
}

/// 앱 최상단에 두는 리스너
class MouseNavListener extends StatelessWidget {
  const MouseNavListener({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          if (e.kind != PointerDeviceKind.mouse) return;
          if (e.buttons & kBackMouseButton != 0) {
            MouseNav.back();
          } else if (e.buttons & kForwardMouseButton != 0) {
            MouseNav.forward();
          }
        },
        child: child,
      );
}
