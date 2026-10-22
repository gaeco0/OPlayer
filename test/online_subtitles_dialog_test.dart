import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oplayer/core/media_item.dart';
import 'package:oplayer/core/plugins/plugin.dart';
import 'package:oplayer/core/plugins/plugin_store.dart';
import 'package:oplayer/core/plugins/subtitle_plugins.dart';
import 'package:oplayer/features/player/player_controller.dart';
import 'package:oplayer/features/player/widgets/online_subtitles_dialog.dart';

class _Player extends ChangeNotifier implements PlayerController {
  _Player(this.onlineSubtitles);
  @override
  final SubtitlePlugins onlineSubtitles;
  @override
  MediaItem current = const MediaItem(key: 'movie', uri: 'movie', title: 'Example.Movie.mkv');
  @override
  String get title => current.title;
  Map<String, dynamic>? selected;
  bool Function()? active;
  Completer<bool>? completion;
  @override
  Future<bool> applyOnlineSubtitle(
    OPlugin plugin,
    Map<String, dynamic> item, {
    int? generation,
    bool Function()? active,
  }) async {
    selected = item;
    this.active = active;
    return completion == null ? true : completion!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Subtitles extends SubtitlePlugins {
  _Subtitles(super.store, this.empty);
  final bool empty;
  @override
  Future<SubtitleResults> search(OPlugin plugin, String query, String language, {int page = 1}) async {
    expect(query, 'Example Movie');
    expect(language, 'ko');
    return SubtitleResults(
      empty
          ? []
          : [
              {'id': '1', 'title': 'Example Korean', 'language': 'ko'},
            ],
      page,
      page,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final store = PluginStore.instance;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await store.init();
    await store.setEnabled('subtitle.opensubtitles', false);
    await store.load(
      '// @oplayer ${jsonEncode({
        'api': 4,
        'id': 'subtitle.dialog',
        'name': 'Dialog provider',
        'version': '1',
        'kind': 'subtitle',
        'hosts': ['provider.example'],
      })}\nglobalThis.plugin={async searchSubtitles({query,language}){return OPlayer.request("https://provider.example/subtitles",{query:{query,language}})},downloadSubtitle(){return null}};',
    );
    await store.setCredentials('subtitle.dialog', {});
  });

  Future<_Player> open(WidgetTester tester, {bool empty = false}) async {
    final player = _Player(_Subtitles(store, empty));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showOnlineSubtitles(context, player), child: const Text('open')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return player;
  }

  testWidgets('opens with a title-based Korean search and applies the selected result', (tester) async {
    final player = await open(tester);
    expect(find.text('Example Korean'), findsOneWidget);
    await tester.tap(find.text('Example Korean'));
    await tester.pumpAndSettle();
    expect(player.selected?['id'], '1');
    expect(find.byType(OnlineSubtitlesDialog), findsNothing);
  });

  testWidgets('empty searches stay usable and narrow landscape layouts scroll', (tester) async {
    tester.view.physicalSize = const Size(600, 350);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, empty: true);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.textContaining('검색 결과가 없습니다'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing a pending download invalidates its application guard', (tester) async {
    final player = await open(tester);
    player.completion = Completer<bool>();
    await tester.tap(find.text('Example Korean'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(player.active?.call(), true);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(player.active?.call(), false);
    player.completion!.complete(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a changed playback item cannot receive a stale subtitle selection', (tester) async {
    final player = await open(tester);
    player.current = const MediaItem(key: 'next', uri: 'next', title: 'Next movie');
    await tester.tap(find.text('Example Korean'));
    await tester.pumpAndSettle();
    expect(player.selected, isNull);
    expect(find.textContaining('재생 항목이 바뀌었습니다'), findsOneWidget);
  });
}
