import 'dart:async';

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/credential_store.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/accounts/spoof_bridge.dart';
import 'package:wellmagram/core/app/session_manager.dart';
import 'package:wellmagram/core/backends/max/max_backend.dart';
import 'package:wellmagram/core/backends/messenger_backend.dart';
import 'package:test/test.dart';

import 'fake_max_api.dart';
import 'in_memory_secure_storage.dart';

// OPE-3719: extra switch-mode coverage (R2 target: switching keeps exactly
// one live session and never re-enters the new account).
// Scenarios:
// - switch events reach subscribers in exact order (max1, max2, null on remove)
// - concurrent start() calls converge to one live session, one switch event
// - switch back does not re-login the target account (no second connect)
// - re-activating the already-active account emits nothing and keeps state
// - start while the previous switch is still in flight
// - pause() is skipped for the already-paused former active session
// - after removeAccount of the active account liveAccounts shrinks and a
//   new start works
// - gap: no persistence of the active key exists (documented in the PR)

const max1 = AccountKey(network: Network.max, id: 1);
const max2 = AccountKey(network: Network.max, id: 2);
const max3 = AccountKey(network: Network.max, id: 3);

class RecordingApi extends FakeMaxApi {
  int connectCount = 0;
  int pauseCount = 0;

  @override
  Future<void> connectAndLogin() async {
    connectCount++;
    await super.connectAndLogin();
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    await super.pause();
  }
}

class Harness {
  final secureStorage = InMemorySecureStorage();
  late final CredentialStore credentials = CredentialStore(secureStorage);
  final records = <AccountKey, RecordingApi>{};

  late final SessionManager manager = SessionManager(
    mode: SessionMode.switchMode,
    factory: (account) {
      final api = RecordingApi();
      records[account] = api;
      return MaxBackend(
        account: account,
        api: api,
        credentials: credentials,
        specBuilder: SessionSpecBuilder(
          loadSpoofProfile: (a) async => const {
            'deviceId': 'd',
            'appVersion': '26.23.2',
            'buildNumber': 6779,
          },
          loadEndpoint: () async => (host: 'api2.oneme.ru', port: 443),
          loadProxyUrl: () async => null,
        ),
      );
    },
  );

  Future<void> login(AccountKey account, String token) async {
    final existing = secureStorage.data['cred:${account.storageId}'];
    if (existing == null) {
      await credentials.saveToken(account, token);
    }
  }
}

class _NoopBridge implements AccountSpoofStoreBridge {
  @override
  Future<bool> remove(AccountKey account) async => false;
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  test('switch mode: subscribers see the active key changes in order',
      () async {
    final h = Harness();
    await h.login(max1, 'token-1');
    await h.login(max2, 'token-2');

    final seen = <AccountKey?>[];
    final sub = h.manager.activeChanges.listen(seen.add);
    await h.manager.start(max1);
    await h.manager.start(max2);
    await pump();

    expect(seen, [max1, max2]);
    expect(h.manager.activeKey, max2);
    await sub.cancel();
    await h.manager.dispose();
  });

  test('switch mode: null marker from onSwitcherSelected is broadcast',
      () async {
    final h = Harness();
    await h.login(max1, 'token-1');
    await h.manager.start(max1);

    final seen = <AccountKey?>[];
    final sub = h.manager.activeChanges.listen(seen.add);
    await h.manager.onSwitcherSelected(null);
    await pump();

    expect(seen, [null]);
    expect(h.manager.activeKey, isNull);
    expect(h.records[max1]!.pauseCount, 0,
        reason: 'null marker only drops the active marker, sessions stay');
    await sub.cancel();
    await h.manager.dispose();
  });

  test('switch mode: concurrent start() calls converge to one live session',
      () async {
    final h = Harness();
    await h.login(max1, 'token-1');
    await h.login(max2, 'token-2');

    final seen = <AccountKey?>[];
    final sub = h.manager.activeChanges.listen(seen.add);
    // Fire both switches without awaiting in between.
    final futures = [
      h.manager.start(max1),
      h.manager.start(max2),
    ];
    await Future.wait(futures);
    await pump();

    expect(h.manager.activeKey, max2);
    expect(h.records[max2]!.backend, isNotNull);
    expect(h.manager.liveAccounts.length, 2);
    // Both accounts got a backend and the latecomer is the live one.
    expect(h.records[max2]!.state, BackendState.online);
    // Whatever the interleaving, at most one backend is online now.
    final online = h.records.values
        .where((api) => api.state == BackendState.online)
        .length;
    expect(online, 1,
        reason: 'switch mode: exactly one live session after a switch');
    expect(seen, containsAll([max1, max2]));
    await sub.cancel();
    await h.manager.dispose();
  });

  test('switch mode: switching back does not re-login the target account',
      () async {
    final h = Harness();
    await h.login(max1, 'token-1');
    await h.login(max2, 'token-2');

    await h.manager.start(max1);
    await h.manager.start(max2);
    await h.manager.start(max1);
    await pump();

    expect(h.manager.activeKey, max1);
    expect(h.records[max1]!.connectCount, 1,
        reason: 'R2: switching ≤1s without re-entering the account — '
            'the backend is resumed, not re-created or re-logged-in');
    expect(h.records[max1]!.lastLoginToken, 'token-1');
    expect(h.records[max2]!.state, BackendState.paused);
    await h.manager.dispose();
  });

  test('switch mode: re-activating the active account is a no-op',
      () async {
    final h = Harness();
    await h.login(max1, 'token-1');

    await h.manager.start(max1);
    final seen = <AccountKey?>[];
    final sub = h.manager.activeChanges.listen(seen.add);
    await h.manager.start(max1);
    await pump();

    expect(seen, [max1]);
    expect(h.records[max1]!.connectCount, 1);
    expect(h.records[max1]!.pauseCount, 0,
        reason: 'the active session must not be paused by its own activation');
    await sub.cancel();
    await h.manager.dispose();
  });

  test('switch mode: new start while the previous switch is in flight',
      () async {
    final h = Harness();
    await h.login(max1, 'token-1');
    await h.login(max2, 'token-2');
    await h.login(max3, 'token-3');

    final first = h.manager.start(max1);
    final second = h.manager.start(max2);
    final third = h.manager.start(max3);
    await Future.wait([first, second, third]);
    await pump();

    expect(h.manager.activeKey, max3);
    expect(h.records[max3]!.state, BackendState.online);
    final online = h.records.values
        .where((api) => api.state == BackendState.online)
        .length;
    expect(online, 1);
    await h.manager.dispose();
  });

  test('switch mode: already-paused former active is not paused again',
      () async {
    final h = Harness();
    await h.login(max1, 'token-1');
    await h.login(max2, 'token-2');

    await h.manager.start(max1);
    await h.manager.pause(max1);
    expect(h.records[max1]!.pauseCount, 1);

    await h.manager.start(max2);
    expect(h.records[max1]!.pauseCount, 1,
        reason: 'pause() must be skipped for an already-paused backend');
    expect(h.manager.activeKey, max2);
    await h.manager.dispose();
  });

  test('switch mode: state after removing the active account', () async {
    final h = Harness();
    await h.login(max1, 'token-1');
    await h.login(max2, 'token-2');
    await h.manager.start(max1);
    await h.manager.start(max2);

    final seen = <AccountKey?>[];
    final sub = h.manager.activeChanges.listen(seen.add);
    await h.manager.removeAccount(
      max2,
      credentials: h.credentials,
      spoofBridge: _NoopBridge(),
    );
    await pump();

    expect(seen, [null],
        reason: 'removing the active account must broadcast the null marker');
    expect(h.manager.activeKey, isNull);
    expect(h.manager.liveAccounts, [max1]);
    expect(h.manager.backendOf(max2), isNull);
    expect(h.records[max2]!.disposed, isTrue);
    // The other account keeps its (paused) session and can be activated.
    final revived = await h.manager.start(max1);
    await pump();
    expect(revived.state, BackendState.online);
    expect(h.manager.activeKey, max1);
    await sub.cancel();
    await h.manager.dispose();
  });

  test('switch mode: removeAccount of a non-active account keeps the marker',
      () async {
    final h = Harness();
    await h.login(max1, 'token-1');
    await h.login(max2, 'token-2');
    await h.manager.start(max1);

    final seen = <AccountKey?>[];
    final sub = h.manager.activeChanges.listen(seen.add);
    await h.manager.removeAccount(
      max2,
      credentials: h.credentials,
      spoofBridge: _NoopBridge(),
    );
    await pump();

    expect(seen, isEmpty,
        reason: 'removing a non-active account must not touch the marker');
    expect(h.manager.activeKey, max1);
    await sub.cancel();
    await h.manager.dispose();
  });
}
