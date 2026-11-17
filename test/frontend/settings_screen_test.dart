// ignore_for_file: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/account_profile.dart';
import 'package:wellmagram/core/accounts/account_registry.dart';
import 'package:wellmagram/core/accounts/accounts_store.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/app/session_manager.dart';
import 'package:wellmagram/core/backends/telegram/td_ghost.dart';
import 'package:wellmagram/core/storage/spoof_profile_store.dart';
import 'package:wellmagram/frontend/settings/settings_screen.dart';

class _Prefs implements SettingsPrefs, SpoofPrefsLike {
  final values = <String, String>{};
  @override
  String? getString(String key) => values[key];
  @override
  Future<void> setString(String key, String value) async => values[key] = value;
  @override
  Future<void> remove(String key) async => values.remove(key);
}

void main() {
  late AccountRegistry registry;
  late _Prefs prefs;
  late SpoofProfileStore spoof;
  var modeCalls = <SessionMode>[];
  var ghost = TdGhostSettings.off;

  setUp(() async {
    prefs = _Prefs();
    spoof = SpoofProfileStore(prefs: prefs, random: SeededSpoofRandom(4));
    registry = AccountRegistry(store: InMemoryAccountsStore());
    await registry.load();
    modeCalls = [];
    ghost = TdGhostSettings.off;
  });

  tearDown(() async => registry.dispose());

  Widget screen() => MaterialApp(
        home: SettingsScreen(
          registry: registry,
          spoofProfiles: spoof,
          prefs: prefs,
          setMode: (mode) async => modeCalls.add(mode),
          loadGhost: (_) async => ghost,
          saveGhost: (_, value) async => ghost = value,
        ),
      );

  testWidgets('renders sections with an empty registry', (tester) async {
    await tester.pumpWidget(screen());
    expect(find.text('Настройки'), findsOneWidget);
    expect(find.text('Сети'), findsOneWidget);
    await tester.tap(find.text('Аккаунты').last);
    await tester.pumpAndSettle();
    expect(find.text('Аккаунтов пока нет'), findsOneWidget);
  });

  testWidgets('mode selection invokes the session mode setter', (tester) async {
    await tester.pumpWidget(screen());
    await tester.tap(find.text('Режимы сессий').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Параллельно'));
    await tester.pumpAndSettle();
    expect(modeCalls, [SessionMode.parallel]);
  });

  testWidgets('ghost toggle persists for selected account', (tester) async {
    const key = AccountKey(network: Network.telegram, id: 17);
    await registry.add(const AccountProfile(
      key: key,
      displayName: 'Test',
      phone: '',
      updatedAt: 1,
    ));
    await tester.pumpWidget(screen());
    await tester.tap(find.text('Ghost').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Скрыть прочтение'));
    await tester.pumpAndSettle();
    expect(ghost.ghostRead, isTrue);
    expect(ghost.ghostTyping, isFalse);
  });
}
