import 'dart:io';

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/app/tls_gate.dart';
import 'package:wellmagram/core/backends/max/max_api_seam.dart';
import 'package:test/test.dart';

void main() {
  const account = AccountKey(network: Network.max, id: 42);

  SessionSpec specWith({bool insecureTls = false}) => SessionSpec.fromMap({
        'deviceId': 'd',
        'appVersion': '26.23.2',
        'buildNumber': 6779,
        'insecureTls': insecureTls,
      });

  group('tls release gate (plan T-5.2, invariant S6)', () {
    test('debug semantics: insecureTls passes the gate unchanged', () {
      debugSemantics = true; // kDebugMode == true semantics
      addTearDown(() => debugSemantics = true);
      final spec = specWith(insecureTls: true);
      final gated = applyTlsReleaseGate(spec);
      expect(gated.insecureTls, isTrue, reason: 'flag must work in debug');
    });

    test('debug semantics: gate is a no-op (identical) when flag is false',
        () {
      debugSemantics = true;
      addTearDown(() => debugSemantics = true);
      final spec = specWith();
      expect(identical(applyTlsReleaseGate(spec), spec), isTrue);
    });

    test('release semantics: gate forces insecureTls to false', () {
      debugSemantics = false; // kDebugMode == false (release AOT) semantics
      addTearDown(() => debugSemantics = true);
      final gated = applyTlsReleaseGate(specWith(insecureTls: true));
      expect(gated.insecureTls, isFalse,
          reason: 'insecure TLS must be unreachable in release');
      // Everything else survives the gate.
      expect(gated.deviceId, 'd');
      expect(gated.appVersion, '26.23.2');
      expect(gated.buildNumber, 6779);
    });

    test('release semantics: gate is a no-op when flag is already false', () {
      debugSemantics = false;
      addTearDown(() => debugSemantics = true);
      final spec = specWith();
      expect(identical(applyTlsReleaseGate(spec), spec), isTrue);
    });

    test('tlsInsecureAllowed tracks debug semantics', () {
      debugSemantics = false;
      addTearDown(() => debugSemantics = true);
      expect(tlsInsecureAllowed, isFalse);
      debugSemantics = true;
      expect(tlsInsecureAllowed, isTrue);
    });

    test('SessionSpecBuilder applies the gate (debug semantics)', () async {
      debugSemantics = true;
      addTearDown(() => debugSemantics = true);
      final builder = SessionSpecBuilder(
        loadSpoofProfile: (a) async => {'insecureTls': true},
        loadEndpoint: () async => (host: 'api2.oneme.ru', port: 443),
        loadProxyUrl: () async => null,
      );
      final spec = await builder.build(account);
      expect(spec.insecureTls, isTrue);
    });

    test('SessionSpecBuilder applies the gate (release semantics)', () async {
      debugSemantics = false;
      addTearDown(() => debugSemantics = true);
      final builder = SessionSpecBuilder(
        loadSpoofProfile: (a) async => {'insecureTls': true},
        loadEndpoint: () async => (host: 'api2.oneme.ru', port: 443),
        loadProxyUrl: () async => null,
      );
      final spec = await builder.build(account);
      expect(spec.insecureTls, isFalse,
          reason: 'builder output must be gated even if config asks for it');
      expect(spec.host, 'api2.oneme.ru');
    });
  });

  group('static source-scan: insecure path is behind the compile-time gate',
      () {
    // S6 is a compile-time guarantee, so we assert it on the source, not on
    // runtime behaviour: every assignment of `insecureTls: true` outside the
    // gate module and this test must exist only inside the gate's
    // debug-guarded code, and `debugSemantics` must never be flipped to a
    // release-permitting value outside lib/core/app/tls_gate.dart.
    test('no production code assigns debugSemantics', () async {
      final libDir = Directory('lib');
      final offenders = <String>[];
      await for (final e in libDir.list(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final src = await e.readAsString();
        if (e.path == 'lib/core/app/tls_gate.dart') continue;
        if (RegExp(r'debugSemantics\s*=').hasMatch(src)) {
          offenders.add(e.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'only tls_gate.dart may define/assign debugSemantics; '
              'found assignments in: $offenders');
    });

    test('tls_gate.dart is the only module reading the env key', () async {
      final libDir = Directory('lib');
      final offenders = <String>[];
      await for (final e in libDir.list(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final src = await e.readAsString();
        if (e.path == 'lib/core/app/tls_gate.dart') continue;
        if (src.contains(devTlsInsecureEnvKey)) {
          offenders.add(e.path);
        }
      }
      expect(offenders, isEmpty,
          reason: 'the dev_tls_insecure env key must be consulted only '
              'through the gate; found in: $offenders');
    });

    test('insecureTls: true literals exist only in tests', () async {
      final offenders = <String>[];
      final dirs = [Directory('lib'), Directory('bin')];
      for (final d in dirs) {
        if (!d.existsSync()) continue;
        await for (final e in d.list(recursive: true)) {
          if (e is! File || !e.path.endsWith('.dart')) continue;
          final src = await e.readAsString();
          if (RegExp(r'insecureTls\s*:\s*true').hasMatch(src)) {
            offenders.add(e.path);
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'production code must not hard-enable insecureTls; '
              'found in: $offenders');
    });

    test('gate module references debug semantics, not runtime switches',
        () async {
      final src =
          await File('lib/core/app/tls_gate.dart').readAsString();
      expect(src.contains('debugSemantics'), isTrue);
      // The gate must not grow env-driven runtime bypasses: the only place
      // the env key may appear in lib/ is this module, and even here only
      // as documentation of the debug tooling contract.
      expect(RegExp(r'Platform\.environment').hasMatch(src), isFalse,
          reason: 'the gate must be compile-time, not a runtime env check');
    });
  });
}
