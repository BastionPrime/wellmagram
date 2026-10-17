import 'dart:convert';

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/account_profile.dart';
import 'package:wellmagram/core/accounts/accounts_codec.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:test/test.dart';

AccountProfile profile(String net, int id, {String name = '', String phone = ''}) =>
    AccountProfile(
      key: AccountKey(network: Network.tryParse(net)!, id: id),
      displayName: name,
      phone: phone,
      updatedAt: 1234567,
    );

void main() {
  test('encode/decode round-trips the snapshot', () {
    final raw = AccountsCodec.encode(
      profiles: [profile('max', 1, name: 'A'), profile('tg', 2, name: 'B')],
      activeKey: const AccountKey(network: Network.telegram, id: 2),
    );
    final decoded = AccountsCodec.decode(raw)!;
    expect(decoded.profiles, hasLength(2));
    expect(decoded.profiles.first.key.storageId, 'max:1');
    expect(decoded.activeKey!.storageId, 'tg:2');
  });

  test('encode/decode round-trips every AccountProfile field', () {
    final original = <AccountProfile>[
      AccountProfile(
        key: const AccountKey(network: Network.max, id: 42),
        displayName: 'Work Account',
        phone: '+79990001122',
        updatedAt: 987654321012,
      ),
      AccountProfile(
        key: const AccountKey(network: Network.telegram, id: 7),
        // Defaults (empty strings / zero) must survive the trip too.
        displayName: '',
        phone: '',
        updatedAt: 0,
      ),
    ];
    final raw = AccountsCodec.encode(
      profiles: original,
      activeKey: const AccountKey(network: Network.max, id: 42),
    );
    final decoded = AccountsCodec.decode(raw)!;
    expect(decoded.profiles, original);
    expect(decoded.activeKey, original.first.key);
  });

  test('snapshot JSON has a fixed shape: version, accounts, active', () {
    final json = AccountsCodec.snapshotToJson(
      profiles: [profile('max', 1)],
      activeKey: const AccountKey(network: Network.max, id: 1),
    );
    expect(json.keys.toList(), containsAll(['version', 'accounts', 'active']));
    expect(json['accounts'], isA<List<dynamic>>());
    expect(json['active'], 'max:1');
    // The stored account object keeps the documented field set.
    expect(
      json['accounts'].first as Map,
      containsPair('network', 'max'),
    );
  });

  test('empty registry round-trips with no active key', () {
    final raw = AccountsCodec.encode(profiles: [], activeKey: null);
    final decoded = AccountsCodec.decode(raw)!;
    expect(decoded.profiles, isEmpty);
    expect(decoded.activeKey, isNull);
    // Textual contract for the empty registry: version + empty list + null.
    expect(jsonDecode(raw), {'version': 1, 'accounts': <Object>[], 'active': null});
  });

  test('decode ignores unknown fields from future schema versions', () {
    final raw = jsonEncode({
      'version': 1,
      'future_field': {'nested': [1, 2, 3]},
      'accounts': [
        {
          'network': 'max',
          'id': 5,
          'display_name': 'X',
          'phone': '+79990000000',
          'updated_at': 77,
          'some_future_profile_field': 'ignored',
        },
      ],
      'active': 'max:5',
      'another_unknown': 42,
    });
    final decoded = AccountsCodec.decode(raw)!;
    expect(decoded.profiles, hasLength(1));
    final p = decoded.profiles.single;
    expect(p.key.storageId, 'max:5');
    expect(p.displayName, 'X');
    expect(p.phone, '+79990000000');
    expect(p.updatedAt, 77);
    expect(decoded.activeKey!.storageId, 'max:5');
  });

  test('decode returns null for empty and invalid JSON', () {
    expect(AccountsCodec.decode(null), isNull);
    expect(AccountsCodec.decode(''), isNull);
    expect(AccountsCodec.decode('not json'), isNull);
    expect(AccountsCodec.decode('[]'), isNull);
  });

  test('decode rejects snapshots from a newer version', () {
    final raw = jsonEncode({'version': 99, 'accounts': <Object>[]});
    expect(AccountsCodec.decode(raw), isNull);
  });

  test('decode rejects snapshots with a missing or non-int version field', () {
    // The contract is strict: a stored snapshot must carry an integer
    // version <= current. Anything else (legacy, absent, wrong type) is
    // rejected rather than guessed at.
    final noVersion = jsonEncode({
      'accounts': [
        {'network': 'tg', 'id': 3},
      ],
      'active': 'tg:3',
    });
    expect(AccountsCodec.decode(noVersion), isNull);
    final stringVersion = jsonEncode({'version': '1', 'accounts': []});
    expect(AccountsCodec.decode(stringVersion), isNull);
  });

  test('decode drops unknown networks and bad entries', () {
    final raw = jsonEncode({
      'version': 1,
      'accounts': [
        {'network': 'unknown', 'id': 1},
        {'network': 'max', 'id': 2},
        {'network': 'max'},
        'junk',
      ],
      'active': 'max:2',
    });
    final decoded = AccountsCodec.decode(raw)!;
    expect(decoded.profiles, hasLength(1));
    expect(decoded.profiles.first.key.id, 2);
  });

  test('decode ignores active key missing from profiles', () {
    final raw = jsonEncode({
      'version': 1,
      'accounts': [
        {'network': 'max', 'id': 1},
      ],
      'active': 'tg:9',
    });
    final decoded = AccountsCodec.decode(raw)!;
    expect(decoded.activeKey, isNull);
  });

  test('decoded profiles are sorted by key', () {
    final raw = AccountsCodec.encode(
      profiles: [profile('tg', 5), profile('max', 9), profile('max', 2)],
      activeKey: null,
    );
    final decoded = AccountsCodec.decode(raw)!;
    expect(
      decoded.profiles.map((p) => p.key.storageId).toList(),
      ['max:2', 'max:9', 'tg:5'],
    );
  });

  test('snapshot JSON contains no secret-looking fields', () {
    final raw = AccountsCodec.encode(
      profiles: [
        AccountProfile(
          key: const AccountKey(network: Network.max, id: 1),
          displayName: 'A',
          phone: '+700****0001',
          updatedAt: 1,
        ),
      ],
      activeKey: const AccountKey(network: Network.max, id: 1),
    );
    expect(raw, isNot(contains('token')));
    expect(raw, isNot(contains('secret')));
    expect(raw, isNot(contains('auth_token')));
  });

  test('stored JSON keys are exactly the documented non-secret fields', () {
    final json = AccountsCodec.snapshotToJson(
      profiles: [
        AccountProfile(
          key: const AccountKey(network: Network.telegram, id: 9),
          displayName: 'D',
          phone: '+700****0009',
          updatedAt: 5,
        ),
      ],
      activeKey: const AccountKey(network: Network.telegram, id: 9),
    );
    // Registry-level allowlist: anything else (e.g. a future secret leak)
    // fails this test.
    expect(json.keys.toSet(), {'version', 'accounts', 'active'});
    final account = (json['accounts'] as List).single as Map<String, dynamic>;
    expect(account.keys.toSet(), {'network', 'id', 'display_name', 'phone', 'updated_at'});
  });

  test('the schema version is fixed and documented', () {
    // The wire format of the prefs snapshot: pinned version 1.
    // Bump `_currentVersion` in AccountsCodec together with this test and a
    // migration entry, never silently.
    const expectedSchemaVersion = 1;
    final raw = AccountsCodec.encode(profiles: [], activeKey: null);
    final decodedJson = jsonDecode(raw) as Map<String, dynamic>;
    expect(decodedJson['version'], expectedSchemaVersion);
    // Same-version snapshots round-trip through decode.
    expect(AccountsCodec.decode(raw), isNotNull);
    // Older or equal versions decode; strictly newer do not.
    final v1 = jsonEncode({'version': expectedSchemaVersion, 'accounts': []});
    expect(AccountsCodec.decode(v1), isNotNull);
    final vNext =
        jsonEncode({'version': expectedSchemaVersion + 1, 'accounts': []});
    expect(AccountsCodec.decode(vNext), isNull);
  });
}
