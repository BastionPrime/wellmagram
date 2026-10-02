

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/account_profile.dart';
import 'package:wellmagram/core/accounts/account_registry.dart';
import 'package:wellmagram/core/accounts/account_registry_event.dart';
import 'package:wellmagram/core/accounts/accounts_store.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:test/test.dart';

/// Pumps the event loop once so broadcast-stream events reach listeners
/// listening across an await (buffered subscription delivery).
Future<void> pump([int turns = 1]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

AccountProfile profile(Network net, int id, {String name = '', String phone = ''}) =>
    AccountProfile(
      key: AccountKey(network: net, id: id),
      displayName: name.isEmpty ? 'n$id' : name,
      phone: phone,
      updatedAt: id * 1000,
    );

void main() {
  late InMemoryAccountsStore store;
  late AccountRegistry registry;

  setUp(() {
    store = InMemoryAccountsStore();
    registry = AccountRegistry(store: store);
  });

  tearDown(() async {
    await registry.dispose();
  });

  test('load() is required before any access', () {
    expect(
      () => registry.profiles,
      throwsStateError,
    );
    expect(registry.isLoaded, isFalse);
  });

  test('add() persists and emits added event', () async {
    await registry.load();
    final events = <AccountRegistryEvent>[];
    final sub = registry.events.listen(events.add);
    await registry.add(profile(Network.max, 2));
    await Future<void>.delayed(Duration.zero);
    expect(registry.profiles, hasLength(1));
    expect(events.map((e) => e.kind), [
      AccountRegistryEventKind.added,
      AccountRegistryEventKind.activeChanged,
    ]);
    await sub.cancel();
  });

  test('first added account becomes active', () async {
    await registry.load();
    final events = <AccountRegistryEvent>[];
    final sub = registry.events.listen(events.add);
    await registry.add(profile(Network.max, 1));
    await Future<void>.delayed(Duration.zero);
    expect(registry.activeKey, const AccountKey(network: Network.max, id: 1));
    expect(
      events.map((e) => e.kind),
      containsAll([AccountRegistryEventKind.added, AccountRegistryEventKind.activeChanged]),
    );
    await sub.cancel();
  });

  test('second added account does not steal active', () async {
    await registry.load();
    await registry.add(profile(Network.max, 1));
    await registry.add(profile(Network.max, 2));
    expect(registry.activeKey, const AccountKey(network: Network.max, id: 1));
  });

  test('add() of existing key merges non-empty fields', () async {
    await registry.load();
    await registry.add(profile(Network.max, 1, name: 'Old', phone: '+1'));
    await registry.add(profile(Network.max, 1, name: 'New'));
    final p = registry.profileOf(const AccountKey(network: Network.max, id: 1))!;
    expect(p.displayName, 'New');
    expect(p.phone, '+1');
    expect(registry.profiles, hasLength(1));
  });

  test('remove() drops the profile and clears active when needed', () async {
    await registry.load();
    await registry.add(profile(Network.max, 1));
    await registry.add(profile(Network.max, 2));
    await registry.setActive(const AccountKey(network: Network.max, id: 2));
    await registry.remove(const AccountKey(network: Network.max, id: 2));
    expect(registry.profiles, hasLength(1));
    expect(registry.activeKey, isNull);
  });

  test('remove() of missing key is a no-op', () async {
    await registry.load();
    await registry.remove(const AccountKey(network: Network.max, id: 99));
    expect(registry.profiles, isEmpty);
  });

  test('setActive() persists the choice', () async {
    await registry.load();
    await registry.add(profile(Network.max, 1));
    await registry.add(profile(Network.max, 2));
    await registry.setActive(const AccountKey(network: Network.max, id: 2));

    final second = AccountRegistry(store: store);
    await second.load();
    expect(
      second.activeKey,
      const AccountKey(network: Network.max, id: 2),
    );
    await second.dispose();
  });

  test('setActive() ignores unknown keys', () async {
    await registry.load();
    await registry.add(profile(Network.max, 1));
    await registry.setActive(const AccountKey(network: Network.telegram, id: 5));
    expect(registry.activeKey, const AccountKey(network: Network.max, id: 1));
  });

  test('registry state survives a store round-trip', () async {
    await registry.load();
    await registry.add(profile(Network.max, 1, name: 'One'));
    await registry.add(profile(Network.telegram, 4, name: 'Four'));

    final revived = AccountRegistry(store: store);
    await revived.load();
    expect(revived.profiles, hasLength(2));
    expect(
      revived.profileOf(const AccountKey(network: Network.telegram, id: 4))!
          .displayName,
      'Four',
    );
    await revived.dispose();
  });

  test('profiles list is sorted and unmodifiable', () async {
    await registry.load();
    await registry.add(profile(Network.telegram, 3));
    await registry.add(profile(Network.max, 8));
    await registry.add(profile(Network.max, 1));
    expect(
      registry.profiles.map((p) => p.key.storageId).toList(),
      ['max:1', 'max:8', 'tg:3'],
    );
    expect(
      () => registry.profiles.add(profile(Network.max, 2)),
      throwsUnsupportedError,
    );
  });

  test('update() rewrites stored fields', () async {
    await registry.load();
    await registry.add(profile(Network.max, 1, name: 'Old'));
    await registry.update(profile(Network.max, 1, name: 'New'));
    expect(
      registry.profileOf(const AccountKey(network: Network.max, id: 1))!
          .displayName,
      'New',
    );
  });

  test('update() of unknown key is a no-op', () async {
    await registry.load();
    await registry.update(profile(Network.max, 9));
    expect(registry.profiles, isEmpty);
  });

  test('load() twice is idempotent', () async {
    await registry.load();
    await registry.add(profile(Network.max, 1));
    await registry.load();
    expect(registry.profiles, hasLength(1));
  });

  // -- sequential add/remove ordering -----------------------------

  test('events arrive in operation order for sequential add/remove',
      () async {
    await registry.load();
    final events = <AccountRegistryEvent>[];
    final sub = registry.events.listen(events.add);
    await registry.add(profile(Network.max, 1));
    await registry.add(profile(Network.max, 2));
    await registry.remove(const AccountKey(network: Network.max, id: 2));
    await registry.remove(const AccountKey(network: Network.max, id: 1));
    await pump();
    expect(
      events
          .map((e) => (e.kind.name, e.key.id))
          .map((r) => '${r.$1}:${r.$2}')
          .toList(),
      [
        'added:1',
        'activeChanged:1', // first add made 1 active
        'added:2',
        'removed:2',
        'removed:1',
        'activeChanged:1', // after removing the active 1, active clears
      ],
    );
    await sub.cancel();
  });

  test('remove of a non-active account emits removed only', () async {
    await registry.load();
    await registry.add(profile(Network.max, 1));
    await registry.add(profile(Network.max, 2));
    final events = <AccountRegistryEvent>[];
    final sub = registry.events.listen(events.add);
    await registry.remove(const AccountKey(network: Network.max, id: 1));
    await pump();
    // 1 was the active account (first add), so removing it also clears active.
    expect(
      events.map((e) => e.kind),
      [AccountRegistryEventKind.removed, AccountRegistryEventKind.activeChanged],
    );
    expect(registry.activeKey, isNull);
    await sub.cancel();
  });

  // -- removing a missing key --------------------------------------

  test('remove of missing key is silent (no event, no persist)', () async {
    await registry.load();
    var writes = 0;
    final counting = _CountingStore(store, onWrite: () => writes++);
    final countingRegistry = AccountRegistry(store: counting);
    await countingRegistry.load();
    final events = <AccountRegistryEvent>[];
    final sub = countingRegistry.events.listen(events.add);
    await countingRegistry.remove(const AccountKey(network: Network.max, id: 99));
    await pump();
    expect(events, isEmpty);
    expect(writes, 0);
    await countingRegistry.dispose();
    await sub.cancel();
  });

  // -- repeated add of the same key --------------------------------

  test('repeated add of the same key emits updated, never added twice',
      () async {
    await registry.load();
    final events = <AccountRegistryEvent>[];
    final sub = registry.events.listen(events.add);
    await registry.add(profile(Network.max, 7, name: 'A'));
    await registry.add(profile(Network.max, 7, name: 'B'));
    await pump();
    expect(
      events.map((e) => e.kind).toList(),
      [
        AccountRegistryEventKind.added,
        AccountRegistryEventKind.activeChanged,
        AccountRegistryEventKind.updated,
      ],
    );
    // Update event carries the merged profile's key (same key).
    expect(
      events.last.key,
      const AccountKey(network: Network.max, id: 7),
    );
    expect(registry.profiles, hasLength(1));
    await sub.cancel();
  });

  test('repeated add merges empty new fields into old values', () async {
    await registry.load();
    await registry.add(profile(Network.max, 5, name: 'Old', phone: '+1'));
    final empty = AccountProfile(
      key: const AccountKey(network: Network.max, id: 5),
      displayName: '',
      phone: '',
      updatedAt: 0,
    );
    await registry.add(empty);
    final p = registry.profileOf(const AccountKey(network: Network.max, id: 5))!;
    expect(p.displayName, 'Old');
    expect(p.phone, '+1');
  });

  // -- listener isolation -------------------------------------------

  test('unsubscribed listener stops receiving events', () async {
    await registry.load();
    final gone = <AccountRegistryEvent>[];
    final kept = <AccountRegistryEvent>[];
    final goneSub = registry.events.listen(gone.add);
    final keptSub = registry.events.listen(kept.add);
    await registry.add(profile(Network.max, 1));
    await pump();
    await goneSub.cancel();
    await registry.add(profile(Network.max, 2));
    await pump();
    expect(gone, hasLength(2)); // added:1 + activeChanged:1, nothing after
    expect(gone.last.kind, AccountRegistryEventKind.activeChanged);
    expect(kept, hasLength(3)); // added:1 + activeChanged:1 + added:2
    await keptSub.cancel();
  });

  test('late subscriber sees only events emitted after subscribe', () async {
    await registry.load();
    await registry.add(profile(Network.max, 1));
    final late = <AccountRegistryEvent>[];
    final sub = registry.events.listen(late.add);
    await registry.add(profile(Network.max, 2));
    await pump();
    expect(late.map((e) => e.kind), [AccountRegistryEventKind.added]);
    await sub.cancel();
  });

  test('events stream ends on dispose', () async {
    await registry.load();
    final done = registry.events.drain<void>();
    await registry.dispose();
    await done;
  });

  // -- concurrent mutations are applied in call order --------------

  test('concurrent adds and removes are applied in call order', () async {
    await registry.load();
    final events = <AccountRegistryEvent>[];
    final sub = registry.events.listen(events.add);
    final a = profile(Network.max, 1);
    final b = profile(Network.max, 2);
    // Fire before awaiting: the in-memory map updates synchronously at call
    // time, so by the time each future completes the state reflects the
    // registration order (a, b, remove b), not the persistence order.
    final f1 = registry.add(a);
    final f2 = registry.add(b);
    final f3 = registry.remove(const AccountKey(network: Network.max, id: 2));
    await Future.wait([f1, f2, f3]);
    await pump();
    expect(registry.profiles.map((p) => p.key.id), [1]);
    expect(registry.activeKey, const AccountKey(network: Network.max, id: 1));
    expect(
      events.map((e) => e.kind).toList(),
      [
        AccountRegistryEventKind.added, // a added (first -> also active)
        AccountRegistryEventKind.activeChanged,
        AccountRegistryEventKind.added, // b added
        AccountRegistryEventKind.removed, // b removed (not active)
      ],
    );
    await sub.cancel();
  });
}

/// Store wrapper that counts write() calls without changing semantics.
class _CountingStore implements AccountsStore {
  final AccountsStore _inner;
  final void Function() onWrite;

  _CountingStore(this._inner, {required this.onWrite});

  @override
  Future<({List<AccountProfile> profiles, AccountKey? activeKey})> read() =>
      _inner.read();

  @override
  Future<void> write({
    required List<AccountProfile> profiles,
    required AccountKey? activeKey,
  }) {
    onWrite();
    return _inner.write(profiles: profiles, activeKey: activeKey);
  }
}
