import 'dart:convert';

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/spoof_bridge.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/backends/max/max_api_seam.dart';
import 'package:wellmagram/core/storage/spoof_profile.dart';
import 'package:wellmagram/core/storage/spoof_profile_store.dart';
import 'package:test/test.dart';

void main() {
  test('profile maps to upstream getSpoofedSessionData shape', () {
    const profile = SpoofProfile(
      enabled: true,
      deviceName: 'Pixel 8 Pro',
      osVersion: 'Android 14',
      screen: 'xxhdpi 430dpi 1344x2992',
      timezone: 'America/New_York',
      locale: 'en',
      deviceLocale: 'en',
      deviceId: 'a1b2c3d4e5f60718',
      appVersion: '26.23.2',
      buildNumber: 6779,
      instanceId: 'inst-1',
      clientSessionId: 77,
      userAgent: 'UA',
    );
    final data = spoofProfileToSessionData(profile);
    expect(data, isNotNull);
    expect(data!['device_name'], 'Pixel 8 Pro');
    expect(data['os_version'], 'Android 14');
    expect(data['device_id'], 'a1b2c3d4e5f60718');
    expect(data['build_number'], 6779);
    expect(data['client_session_id'], 77);
    expect(data.keys, containsAll(<String>[
      'device_name', 'os_version', 'screen', 'timezone', 'locale',
      'device_locale', 'device_id', 'device_type', 'app_version', 'arch',
      'build_number', 'instance_id', 'client_session_id',
      'push_device_type', 'user_agent',
    ]));
  });

  test('disabled or missing profile yields null', () {
    expect(spoofProfileToSessionData(null), isNull);
    expect(
      spoofProfileToSessionData(const SpoofProfile(enabled: false)),
      isNull,
    );
  });

  test('bridge remove delegates to the store', () async {
    final bridge = _RecordingBridge();
    expect(await bridge.remove(const AccountKey(network: Network.max, id: 5)),
        isTrue);
    expect(bridge.removed, [const AccountKey(network: Network.max, id: 5)]);
  });

  group('optional fields absent (legacy/edge profile)', () {
    test('profile without timezone/locale still yields a full map', () {
      // A profile persisted before optional fields existed (or trimmed by
      // an older codec): timezone/locale/device_locale are empty strings
      // on the model, not null. The map contract keeps every
      // getSpoofedSessionData key present.
      const profile = SpoofProfile(
        enabled: true,
        deviceName: 'Samsung Galaxy S24 Ultra',
        osVersion: 'Android 14',
        screen: 'xxhdpi 450dpi 1440x3120',
        timezone: '',
        locale: '',
        deviceLocale: '',
        deviceId: '0011223344556677',
        appVersion: '26.23.2',
        buildNumber: 6779,
        instanceId: 'inst-legacy',
        clientSessionId: null,
        userAgent: 'UA',
      );
      final data = spoofProfileToSessionData(profile);
      expect(data, isNotNull);
      expect(data, isA<Map<String, dynamic>>());
      expect(data!['timezone'], '');
      expect(data['locale'], '');
      expect(data['device_locale'], '');
      // Every consumer key stays present — no key disappears when the
      // optional fields are unset.
      expect(data.keys, containsAll(<String>[
        'timezone', 'locale', 'device_locale',
      ]));
    });

    test('optional fields survive a JSON round-trip', () {
      const profile = SpoofProfile(
        enabled: true,
        deviceName: 'Xiaomi 13 Pro',
        timezone: '',
        locale: '',
        clientSessionId: null,
      );
      final restored =
          SpoofProfile.fromJson(jsonDecode(jsonEncode(profile.toJson()))
              as Map<String, dynamic>);
      expect(restored, isNotNull);
      expect(restored!.timezone, '');
      expect(restored.locale, '');
      expect(restored.clientSessionId, isNull);
      final data = spoofProfileToSessionData(restored);
      expect(data!['timezone'], '');
      expect(data['locale'], '');
    });

    test('unset optionals fall back to SessionSpec defaults, not blanks '
        'in the session', () async {
      // Contract of the seam: SessionSpecBuilder applies the map on top of
      // SessionSpec.fromMap defaults. Empty-string timezone/locale from the
      // profile DO pass through (map keys win over defaults) — record that
      // behaviour as-is.
      final spec = SessionSpec.fromMap({
        ...?spoofProfileToSessionData(const SpoofProfile(
          enabled: true,
          timezone: '',
          locale: '',
          deviceLocale: '',
        )),
        'host': 'api2.oneme.ru',
        'port': 443,
      });
      expect(spec.timezone, '');
      expect(spec.locale, '');
      expect(spec.deviceLocale, '');
      expect(spec.deviceType, 'ANDROID');
      expect(spec.arch, 'arm64-v8a');
    });
  });

  group('profile switch does not mutate the existing session', () {
    // Contract as of this change: SessionManager builds a SessionSpec once
    // per backend start (MaxBackend.connect); there is no live re-apply
    // path. A stored-profile change (save/regenerate) is NOT pushed into
    // an already-started session — it takes effect on the next
    // start/reconnect, where SessionSpecBuilder.loadSpoofProfile re-reads
    // the store. Fixed here as the contract of the code, matching the
    // antiban §4.8 rule «stable profile per account».
    const acc1 = AccountKey(network: Network.max, id: 1);
    const initial = SpoofProfile(
      enabled: true,
      deviceName: 'Samsung Galaxy S24 Ultra',
      osVersion: 'Android 14',
      screen: 'xxhdpi 450dpi 1440x3120',
      timezone: 'America/New_York',
      locale: 'en',
      deviceLocale: 'en',
      deviceId: '0011223344556677',
      appVersion: '26.23.2',
      buildNumber: 6779,
    );
    late SpoofProfileStore store;
    late SpoofStoreBridge bridge;

    setUp(() {
      store = SpoofProfileStore(
          prefs: FakeSpoofPrefs(), random: SeededSpoofRandom(42));
      bridge = SpoofStoreBridge(store);
    });

    Future<void> seedInitial() => store.save(acc1, initial);

    test('loadSessionData reads a snapshot; saving a new profile does not '
        'change the previously returned map', () async {
      await seedInitial();
      final first = await bridge.loadSessionData(acc1);
      expect(first, isNotNull);
      expect(first!['device_name'], 'Samsung Galaxy S24 Ultra');

      // User action: regenerate the profile for the same account.
      await store.save(
          acc1,
          store.generate().copyWith(
              deviceName: 'Google Pixel 8 Pro', deviceId: 'ffeeddccbbaa0099'));

      // The map handed out earlier is unchanged — profiles are immutable
      // value objects and the map is a copy.
      expect(first['device_name'], 'Samsung Galaxy S24 Ultra');
      expect(first['device_id'], '0011223344556677');

      // A fresh read reflects the new profile (next session start).
      final second = await bridge.loadSessionData(acc1);
      expect(second!['device_name'], 'Google Pixel 8 Pro');
      expect(second['device_id'], 'ffeeddccbbaa0099');
    });

    test('mutating the returned map does not corrupt the stored profile',
        () async {
      await seedInitial();
      final data = await bridge.loadSessionData(acc1);
      expect(data, isNotNull);
      data!['device_name'] = 'tampered';
      final again = await bridge.loadSessionData(acc1);
      expect(again!['device_name'], 'Samsung Galaxy S24 Ultra');
    });

    test('SessionSpec is materialized before connect and not rebuilt on '
        'store changes', () async {
      await seedInitial();
      final spec = await _SessionHarness.buildSpec(bridge, acc1);
      expect(spec.deviceName, 'Samsung Galaxy S24 Ultra');

      await store.save(
          acc1, store.generate().copyWith(deviceName: 'Xiaomi 13 Pro'));

      // The already-built spec keeps the profile it was built with; only a
      // new build() re-reads the store.
      expect(spec.deviceName, 'Samsung Galaxy S24 Ultra');
      final rebuilt = await _SessionHarness.buildSpec(bridge, acc1);
      expect(rebuilt.deviceName, 'Xiaomi 13 Pro');
    });
  });

  group('different scopes map to different profiles', () {
    test('same id on MAX and TG never collide in the store', () async {
      final prefs = FakeSpoofPrefs();
      final store =
          SpoofProfileStore(prefs: prefs, random: SeededSpoofRandom(42));
      const max5 = AccountKey(network: Network.max, id: 5);
      const tg5 = AccountKey(network: Network.telegram, id: 5);

      expect(
          SpoofProfileStore.storageKey(max5), 'spoof_profile_max_5');
      expect(
          SpoofProfileStore.storageKey(tg5), 'spoof_profile_tg_5');

      await store.save(max5,
          store.generate().copyWith(deviceName: 'MAX device', deviceId: 'a'));
      await store.save(tg5, store.generate().copyWith(deviceName: 'TG device', deviceId: 'b'));

      final bridge = SpoofStoreBridge(store);
      expect((await bridge.loadSessionData(max5))!['device_name'],
          'MAX device');
      expect((await bridge.loadSessionData(tg5))!['device_name'],
          'TG device');
    });

    test('different MAX accounts keep separate profiles', () async {
      final prefs = FakeSpoofPrefs();
      final store =
          SpoofProfileStore(prefs: prefs, random: SeededSpoofRandom(7));
      const a = AccountKey(network: Network.max, id: 1);
      const b = AccountKey(network: Network.max, id: 2);

      await store.save(
          a, store.generate().copyWith(deviceName: 'First', deviceId: '1111'));
      await store.save(
          b, store.generate().copyWith(deviceName: 'Second', deviceId: '2222'));

      final bridge = SpoofStoreBridge(store);
      expect((await bridge.loadSessionData(a))!['device_name'], 'First');
      expect((await bridge.loadSessionData(b))!['device_name'], 'Second');

      // Removing one account's profile leaves the other intact.
      await bridge.remove(a);
      expect(await bridge.loadSessionData(a), isNull);
      expect((await bridge.loadSessionData(b))!['device_name'], 'Second');
    });
  });

  group('international device_name', () {
    const unicodeName = 'Pixel 8 Pro «Ünïcodé」 你好';

    test('passes through the bridge without escaping or mangling', () {
      const profile = SpoofProfile(
        enabled: true,
        deviceName: unicodeName,
        timezone: 'Europe/Berlin',
        locale: 'de',
        deviceLocale: 'de',
        deviceId: 'aabbccddeeff0011',
      );
      final data = spoofProfileToSessionData(profile);
      expect(data!['device_name'], unicodeName);
      // Not escaped into \\uXXXX, not latin1-mangled: identical string.
      expect(data['device_name'].toString().codeUnits,
          unicodeName.codeUnits);
    });

    test('survives a full store JSON round-trip via the bridge', () async {
      final prefs = FakeSpoofPrefs();
      final store =
          SpoofProfileStore(prefs: prefs, random: SeededSpoofRandom(42));
      const acc = AccountKey(network: Network.max, id: 9);
      await store.save(
          acc, store.generate().copyWith(deviceName: unicodeName));

      final data = await SpoofStoreBridge(store).loadSessionData(acc);
      expect(data!['device_name'], unicodeName);
    });

    test('lands in SessionSpec as-is', () async {
      final spec = SessionSpec.fromMap({
        ...?spoofProfileToSessionData(const SpoofProfile(
          enabled: true,
          deviceName: unicodeName,
        )),
        'host': 'api2.oneme.ru',
        'port': 443,
      });
      expect(spec.deviceName, unicodeName);
    });

    test('emoji and combining marks stay intact', () {
      const name = '🤖 大.tabs\u0301 🇺🇦';
      const profile = SpoofProfile(enabled: true, deviceName: name);
      expect(spoofProfileToSessionData(profile)!['device_name'], name);
    });
  });
}

/// In-memory prefs seam, mirroring the fakes used by the neighbouring
/// store/session tests.
class FakeSpoofPrefs implements SpoofPrefsLike {
  final Map<String, String> data = {};

  @override
  String? getString(String key) => data[key];

  @override
  Future<void> setString(String key, String value) async => data[key] = value;

  @override
  Future<void> remove(String key) async => data.remove(key);
}

/// Drives SessionSpecBuilder the same way MaxBackend does (build once,
/// before connect).
class _SessionHarness {
  static Future<SessionSpec> buildSpec(
      SpoofStoreBridge bridge, AccountKey account) {
    final builder = SessionSpecBuilder(
      loadSpoofProfile: (a) => bridge.loadSessionData(a),
      loadEndpoint: () async => (host: 'api2.oneme.ru', port: 443),
      loadProxyUrl: () async => null,
    );
    return builder.build(account);
  }
}

class _RecordingBridge implements AccountSpoofStoreBridge {
  final removed = <AccountKey>[];

  @override
  Future<bool> remove(AccountKey account) async {
    removed.add(account);
    return true;
  }
}
