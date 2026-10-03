// Live smoke of the production Dart FFI TDLib adapter (TdFfiClient).
//
// Replays the verification milestone from the changelog — create → receive →
// updateAuthorizationState(authorizationStateWaitTdlibParameters) → close →
// clean teardown — as a repeatable command-line tool with timings, a hard
// deadline and exit code 0/1.
//
// Usage:
//   dart run tools/ffi_smoke.dart [path-to-libtdjson] [options]
//
// Options:
//   --timeout <seconds>   overall deadline (default 30; range 1..300)
//   --verbose             print every update @type received
//
// The library path may also come from the WM_TD_JSON_LIB environment
// variable. The bundled jniLibs/arm64-v8a binary is an Android library and
// is not searched automatically — on a host, pass an explicit library
// matching the host architecture.
//
// Exit codes: 0 = smoke passed; 1 = smoke failed (timeout, missing expected
// update, adapter error, non-clean teardown, bad usage).
library;

import 'dart:async';
import 'dart:io';

import 'package:wellmagram/core/backends/telegram/td_ffi_client.dart';

const _defaultTimeoutSeconds = 30;

final Stopwatch _t0 = Stopwatch()..start();

void _log(String msg) {
  final t = _t0.elapsedMicroseconds / 1000.0;
  stdout.writeln('[+${t.toStringAsFixed(1).padLeft(8)} ms] $msg');
}

class _Args {
  final String? libPath;
  final Duration timeout;
  final bool verbose;

  const _Args({this.libPath, required this.timeout, this.verbose = false});
}

_Args _parseArgs(List<String> argv) {
  String? lib;
  var timeoutSeconds = _defaultTimeoutSeconds;
  var verbose = false;

  var i = 0;
  String? fail;
  while (i < argv.length) {
    final a = argv[i];
    if (a == '--timeout') {
      if (i + 1 >= argv.length || int.tryParse(argv[i + 1]) == null) {
        fail = '--timeout needs an integer seconds value';
        break;
      }
      timeoutSeconds = int.parse(argv[i + 1]);
      i += 2;
    } else if (a == '--verbose') {
      verbose = true;
      i += 1;
    } else if (a.startsWith('-') && a != '-') {
      fail = 'unknown option: $a';
      break;
    } else if (lib == null) {
      lib = a;
      i += 1;
    } else {
      fail = 'unexpected extra argument: $a';
      break;
    }
  }
  if (timeoutSeconds < 1 || timeoutSeconds > 300) {
    fail = '--timeout must be between 1 and 300 seconds';
  }
  if (fail != null) {
    stderr.writeln('ffi_smoke: $fail');
    stderr.writeln('usage: dart run tools/ffi_smoke.dart '
        '[path-to-libtdjson] [--timeout seconds] [--verbose]');
    exit(1);
  }
  return _Args(
      libPath: lib, timeout: Duration(seconds: timeoutSeconds), verbose: verbose);
}

Future<void> main(List<String> argv) async {
  final args = _parseArgs(argv);
  var exitCode = 1; // fail-safe default

  final libPath =
      args.libPath ?? Platform.environment['WM_TD_JSON_LIB'] ?? '';
  if (libPath.isEmpty) {
    stderr.writeln('ffi_smoke: no library path given and WM_TD_JSON_LIB is '
        'not set; pass the host libtdjson path as the first argument');
    exit(1);
  }
  if (!File(libPath).existsSync()) {
    stderr.writeln('ffi_smoke: library not found: $libPath');
    exit(1);
  }

  _log('library: $libPath');

  TdFfiClient? client;
  try {
    // --- create ----------------------------------------------------------
    _log('create: td_json_client_create');
    final swCreate = Stopwatch()..start();
    client = TdFfiClient(libPath);
    _log('create: ok (${swCreate.elapsedMicroseconds / 1000.0} ms; cold '
        'start from process start: ${_t0.elapsedMicroseconds / 1000.0} ms)');

    // TDLib logs to stderr at default verbosity — quiet it down so the
    // smoke output stays readable (a "can be called synchronously" request
    // per the adapter seam contract).
    client.execute(const {'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 1});

    // --- receive: wait for the first authorization state ------------------
    // A fresh client (setTdlibParameters never sent) must report
    // authorizationStateWaitTdlibParameters as its first authorization
    // state — exactly the live smoke point recorded in the changelog.
    final updates = client.updateStream;
    StreamSubscription? debugSub;
    if (args.verbose) {
      debugSub = updates.listen((r) => _log('update: ${r.type}'));
    }
    final swWait = Stopwatch()..start();
    final first = await updates
        .firstWhere((r) => r.type == 'updateAuthorizationState')
        .timeout(args.timeout);
    final waitMs = swWait.elapsedMicroseconds / 1000.0;
    final stateType =
        (first.json['authorization_state'] as Map?)?['@type'] as String? ??
            '<missing>';
    if (stateType != 'authorizationStateWaitTdlibParameters') {
      throw 'expected authorizationStateWaitTdlibParameters as the first '
          'authorization state, got: $stateType';
    }
    _log('receive: updateAuthorizationState($stateType) '
        '(waited ${waitMs.toStringAsFixed(1)} ms)');
    await debugSub?.cancel();

    // --- teardown ---------------------------------------------------------
    // destroy() sends `close`; the receive loop must consume the terminal
    // updateAuthorizationState(authorizationStateClosed) and only then run
    // the native destroy inside its own thread — the UAF-free teardown.
    // A clean teardown is proven behaviourally: destroy() completes within
    // the internal 5 s handshake (otherwise the adapter throws) and the
    // process exits 0 without hanging — the adapter's leak fail-safe
    // (isNativeLeaked) is checked by the unit tests instead.
    _log('destroy: close → stop-flag handshake → native destroy');
    final swTeardown = Stopwatch()..start();
    await client.destroy();
    final teardownMs = swTeardown.elapsedMicroseconds / 1000.0;
    _log('destroy: ok (${teardownMs.toStringAsFixed(1)} ms, no timeout)');

    _log('SMOKE PASS (create → receive → updateAuthorizationState → close)');
    exitCode = 0;
  } on TimeoutException {
    _log('SMOKE FAIL: timed out after ${args.timeout.inSeconds} s waiting '
        'for updateAuthorizationState');
    exitCode = 1;
  } on Object catch (e) {
    // Deliberately broad: any adapter/library error is a smoke failure and
    // must be reported, not rethrown (exit code 1 is the tool's contract).
    _log('SMOKE FAIL: $e');
    exitCode = 1;
  } finally {
    // Best-effort cleanup on the failure path; a repeated destroy is a
    // no-op by the adapter contract.
    try {
      await client?.destroy();
    } on Object catch (_) {}
    unawaited(stdout.flush());
    exit(exitCode);
  }
}
