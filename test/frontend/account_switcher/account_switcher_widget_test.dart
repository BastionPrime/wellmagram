// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/account_profile.dart';
import 'package:wellmagram/core/accounts/account_registry.dart';
import 'package:wellmagram/core/accounts/accounts_store.dart';
import 'package:wellmagram/core/accounts/credential_store.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/app/session_manager.dart';
import 'package:wellmagram/core/backends/max/max_api_seam.dart';
import 'package:wellmagram/core/backends/max/max_backend.dart';
import 'package:wellmagram/frontend/account_switcher/account_switcher_widget.dart';

import '../../fake_max_api.dart';
import '../../in_memory_secure_storage.dart';

void main() {
  late AccountRegistry registry;

  const maxKey1 = AccountKey(network: Network.max, id: 101);
  const maxKey2 = AccountKey(network: Network.max, id: 102);
  const tgKey1 = AccountKey(network: Network.telegram, id: 201);

  const profileMax1 = AccountProfile(
    key: maxKey1,
    displayName: 'Max Alpha',
    phone: '+79991112233',
    updatedAt: 1000,
  );
  const profileMax2 = AccountProfile(
    key: maxKey2,
    displayName: 'Max Beta',
    phone: '+79991112244',
    updatedAt: 1001,
  );
  const profileTg1 = AccountProfile(
    key: tgKey1,
    displayName: 'Telegram Gamma',
    phone: '+79991112255',
    updatedAt: 1002,
  );

  setUp(() async {
    registry = AccountRegistry(store: InMemoryAccountsStore());
    await registry.load();
    await registry.add(profileMax1);
    await registry.add(profileMax2);
    await registry.add(profileTg1);
    await registry.setActive(maxKey1);
  });

  tearDown(() async {
    await registry.dispose();
  });

  Future<SessionManager> createTestSessionManager() async {
    final storage = InMemorySecureStorage();
    final creds = CredentialStore(storage);
    await creds.saveToken(maxKey1, 'token-1');
    await creds.saveToken(maxKey2, 'token-2');
    return SessionManager(
      mode: SessionMode.switchMode,
      factory: (account) {
        final api = FakeMaxApi();
        return MaxBackend(
          account: account,
          api: api,
          credentials: creds,
          specBuilder: SessionSpecBuilder(
            loadSpoofProfile: (a) async => const {
              'deviceId': 'test-device',
              'appVersion': '26.23.2',
              'buildNumber': 6779,
            },
            loadEndpoint: () async => (host: 'api2.oneme.ru', port: 443),
            loadProxyUrl: () async => null,
          ),
        );
      },
    );
  }

  Widget buildScreen({
    AccountRegistry? customRegistry,
    SessionManager? sessionManager,
    Future<void> Function(AccountKey key)? onActivate,
    Map<AccountKey, SessionState>? initialSessionStates,
    Stream<SessionInfo>? sessionInfoStream,
    void Function(Network network)? onAddAccount,
  }) {
    return MaterialApp(
      home: AccountSwitcherWidget(
        registry: customRegistry ?? registry,
        sessionManager: sessionManager,
        onActivate: onActivate,
        initialSessionStates: initialSessionStates ??
            {
              maxKey1: SessionState.online,
              maxKey2: SessionState.degraded,
              tgKey1: SessionState.banned,
            },
        sessionInfoStream: sessionInfoStream,
        onAddAccount: onAddAccount,
      ),
    );
  }

  testWidgets(
      'renders 3 accounts across 2 networks with badges, status, and active marker',
      (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pumpAndSettle();

    // 3 accounts rendered with display names
    expect(find.text('Max Alpha'), findsOneWidget);
    expect(find.text('Max Beta'), findsOneWidget);
    expect(find.text('Telegram Gamma'), findsOneWidget);

    // Network badges present for both networks
    expect(find.text('MAX'), findsWidgets);
    expect(find.text('TG'), findsWidgets);

    // Session status badges from SessionState (online/degraded/banned)
    expect(find.text('online'), findsOneWidget);
    expect(find.text('degraded'), findsOneWidget);
    expect(find.text('banned'), findsOneWidget);

    // Active indicator on active account
    expect(find.byKey(const Key('active_chip')), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  testWidgets('selecting an account invokes activate and updates active marker',
      (tester) async {
    AccountKey? activatedKey;
    await tester.pumpWidget(buildScreen(
      onActivate: (key) async {
        activatedKey = key;
      },
    ));
    await tester.pumpAndSettle();

    expect(registry.activeKey, equals(maxKey1));

    // Tap on Max Beta
    await tester.tap(find.text('Max Beta'));
    await tester.pumpAndSettle();

    expect(activatedKey, equals(maxKey2));
    expect(registry.activeKey, equals(maxKey2));

    // Tap on Telegram Gamma
    await tester.tap(find.text('Telegram Gamma'));
    await tester.pumpAndSettle();

    expect(activatedKey, equals(tgKey1));
    expect(registry.activeKey, equals(tgKey1));
  });

  testWidgets('groups accounts by network in ExpansionTiles', (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('expansion_max')), findsOneWidget);
    expect(find.byKey(const Key('expansion_tg')), findsOneWidget);

    // Verify MAX group header contains count 2, and Telegram group contains count 1
    expect(find.text('MAX (2)'), findsOneWidget);
    expect(find.text('Telegram (1)'), findsOneWidget);
  });

  testWidgets(
      'add account button opens dialog stub referencing T-2.2 and T-1.x',
      (tester) async {
    Network? selectedNetwork;
    await tester.pumpWidget(buildScreen(
      onAddAccount: (net) {
        selectedNetwork = net;
      },
    ));
    await tester.pumpAndSettle();

    // Tap Add Account button
    await tester.tap(find.byKey(const Key('add_account_button')));
    await tester.pumpAndSettle();

    // Verify dialog with options and TODO notice
    expect(find.text('Добавить аккаунт'), findsOneWidget);
    expect(find.text('Выберите сеть для подключения:'), findsOneWidget);
    expect(find.textContaining('Т-2.2 / Т-1.x'), findsOneWidget);

    // Select Telegram option
    await tester.tap(find.byKey(const Key('add_account_option_tg')));
    await tester.pumpAndSettle();

    expect(selectedNetwork, equals(Network.telegram));
    expect(find.textContaining('Т-2.2 / Т-1.x (вне scope)'), findsOneWidget);

    // Dismiss stub dialog
    await tester.tap(find.text('Понятно'));
    await tester.pumpAndSettle();
  });

  testWidgets('stream updates account session state in real time',
      (tester) async {
    final streamController = StreamController<SessionInfo>.broadcast();
    addTearDown(streamController.close);

    await tester.pumpWidget(buildScreen(
      sessionInfoStream: streamController.stream,
    ));
    await tester.pumpAndSettle();

    expect(find.text('online'), findsOneWidget);

    // Emit degraded for maxKey1
    streamController.add(const SessionInfo(
      account: maxKey1,
      state: SessionState.degraded,
    ));
    await tester.pumpAndSettle();

    // Now maxKey1 is degraded and maxKey2 is degraded -> 2 degraded widgets
    expect(find.text('degraded'), findsNWidgets(2));
  });

  testWidgets('renders placeholder when registry is empty', (tester) async {
    final emptyRegistry = AccountRegistry(store: InMemoryAccountsStore());
    await emptyRegistry.load();
    addTearDown(emptyRegistry.dispose);

    await tester.pumpWidget(buildScreen(customRegistry: emptyRegistry));
    await tester.pumpAndSettle();

    expect(find.text('Аккаунтов пока нет'), findsOneWidget);
    expect(find.byKey(const Key('add_account_empty_button')), findsOneWidget);
  });

  test('SessionManager.activate activates MAX and Telegram via registry',
      () async {
    final sessionManager = await createTestSessionManager();
    addTearDown(sessionManager.dispose);

    expect(registry.activeKey, equals(maxKey1));

    // Activating MAX updates SessionManager and registry
    await sessionManager.activate(maxKey2, registry: registry);
    expect(sessionManager.activeKey, equals(maxKey2));
    expect(registry.activeKey, equals(maxKey2));

    // Activating Telegram delegates to registry without throwing UnsupportedError
    await sessionManager.activate(tgKey1, registry: registry);
    expect(registry.activeKey, equals(tgKey1));
  });

  testWidgets(
      'tapping accounts with SessionManager activates MAX and Telegram accounts',
      (tester) async {
    final sessionManager = await createTestSessionManager();
    addTearDown(sessionManager.dispose);
    await sessionManager.start(maxKey1);

    await tester.pumpWidget(buildScreen(
      sessionManager: sessionManager,
    ));
    await tester.pumpAndSettle();

    expect(registry.activeKey, equals(maxKey1));
    expect(sessionManager.activeKey, equals(maxKey1));

    // Tap Max Beta (MAX account)
    await tester.tap(find.text('Max Beta'));
    await tester.pumpAndSettle();

    expect(registry.activeKey, equals(maxKey2));
    expect(sessionManager.activeKey, equals(maxKey2));

    // Tap Telegram Gamma (Telegram account)
    await tester.tap(find.text('Telegram Gamma'));
    await tester.pumpAndSettle();

    expect(registry.activeKey, equals(tgKey1));
    expect(find.byKey(const Key('active_chip')), findsOneWidget);
  });
}
