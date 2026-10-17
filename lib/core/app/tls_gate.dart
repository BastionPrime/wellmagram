/// Compile-time release gate for the insecure-TLS escape hatch (plan T-5.2,
/// invariant S6): `insecureTls` must be unreachable in release builds.
///
/// The flag itself lives in [SessionSpec] inside the MAX backend seam
/// (lib/core/backends/max/max_api_seam.dart). That file is NOT frozen
/// (lib/core/transport/** is the frozen seam per plan §0.1), but the gate is
/// deliberately a separate, dependency-free module so the invariant is
/// enforced in one obvious, statically checkable place.
///
/// `kDebugMode` is a compile-time constant in the Flutter toolchain: it is
/// `true` in debug/profile JIT builds and folded to `false` by the AOT
/// compiler in release builds, which dead-code-eliminates the insecure path.
/// Nothing here depends on the `flutter` package, so pure-Dart unit tests
/// can still reason about both semantics by overriding [debugSemantics].
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:wellmagram/core/backends/max/max_api_seam.dart';

/// Whether this build was compiled with debug semantics — `kDebugMode` from
/// `package:flutter/foundation.dart`, a compile-time constant the Flutter
/// toolchain sets: `true` for debug/profile JIT builds, folded to `false` by
/// the AOT compiler in release builds.
///
/// A mutable top-level so tests can simulate both debug and release
/// semantics. Production code must not reassign it; the static source-scan
/// test (test/tls_release_gate_test.dart) asserts that no file outside this
/// gate module (and the test) assigns it.
bool debugSemantics = kDebugMode;

/// Whether `insecureTls` may be enabled in this build.
///
/// In release builds `kDebugMode` is a compile-time `false`, so
/// `debugSemantics` initializes to `false` and this getter returns a constant
/// `false` that the AOT compiler folds — the insecure path is compiled out.
bool get tlsInsecureAllowed => debugSemantics;

/// Environment variable read by debug tooling to opt into insecure TLS.
/// Never consult it directly; go through [tlsInsecureAllowed] (release
/// builds compile the check out entirely).
const String devTlsInsecureEnvKey = 'WELLMAGRAM_DEV_TLS_INSECURE';

/// Applies the release gate to a [SessionSpec]: forces `insecureTls` to
/// `false` unless this build allows it.
///
/// Use wherever a SessionSpec crosses into the transport layer. Debug
/// semantics: the flag works as configured. Release: the flag is statically
/// unreachable, and [applyTlsReleaseGate] is a no-op that returns a spec
/// with `insecureTls == false` (cheap `identical` fast path).
SessionSpec applyTlsReleaseGate(SessionSpec spec) {
  if (spec.insecureTls && !tlsInsecureAllowed) {
    return SessionSpec.fromMap(
      spec.toSessionOptionsMap()..['insecureTls'] = false,
    );
  }
  return spec;
}
