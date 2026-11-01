/// Session lifecycle management for MAX accounts (plan-v3 Т-1.7).
///
/// Modes (plan 4.2):
/// - switch: exactly one live MAX session, the active account; switching
///   pauses the old backend and resumes the new one (upstream switchAccount
///   semantics, but per-account instead of a shared Api).
/// - parallel: all accounts keep live sessions (ADR-0003 gate, plan 4.6).
///
/// The account_switcher_overlay integration: the overlay's callback is
/// `void Function(int? accountId)` — SessionManager exposes
/// [onSwitcherSelected] with exactly that shape, translating the MAX id
/// into an AccountKey, so the overlay's external behaviour stays unchanged.
library;

import 'dart:async';

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/credential_store.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/accounts/spoof_bridge.dart';
import 'package:wellmagram/core/backends/max/max_backend.dart';
import 'package:wellmagram/core/backends/messenger_backend.dart';

enum SessionMode { switchMode, parallel }

class SessionManager {
  final SessionMode mode;
  final MessengerBackendFactory backendFactory;

  final _backends = <AccountKey, MessengerBackend>{};
  final _activeController = StreamController<AccountKey?>.broadcast();
  AccountKey? _activeKey;
  bool _disposed = false;
  bool _ghostMode = false;

  SessionManager({
    this.mode = SessionMode.switchMode,
    required MessengerBackendFactory factory,
  }) : backendFactory = factory;

  Stream<AccountKey?> get activeChanges => _activeController.stream;
  AccountKey? get activeKey => _activeKey;
  bool get isParallel => mode == SessionMode.parallel;
  List<AccountKey> get liveAccounts => List.unmodifiable(_backends.keys);
  MessengerBackend? backendOf(AccountKey account) => _backends[account];
  bool get isGhostMode => _ghostMode;

  Future<MessengerBackend> start(AccountKey account) async {
    _requireAlive();
    if (mode == SessionMode.switchMode &&
        _activeKey != null &&
        _activeKey != account) {
      await pause(_activeKey!);
    }
    var backend = _backends[account];
    if (backend == null) {
      backend = backendFactory.call(account);
      _backends[account] = backend;
    }
    await _startBackend(backend);
    _activeKey = account;
    _activeController.add(account);
    return backend;
  }

  Future<void> _startBackend(MessengerBackend backend) async {
    if (backend.state == BackendState.disconnected) {
      if (backend is MaxBackend) {
        await backend.connectAndLogin();
      } else {
        await backend.resume();
      }
    } else {
      await backend.resume();
    }
    if (_ghostMode) await backend.setGhostMode(true);
  }

  Future<void> onSwitcherSelected(int? accountId) async {
    _requireAlive();
    if (accountId == null) {
      _activeKey = null;
      _activeController.add(null);
      return;
    }
    await start(AccountKey(network: Network.max, id: accountId));
  }

  Future<void> pause(AccountKey account) async {
    final backend = _backends[account];
    if (backend != null && backend.state != BackendState.paused) {
      await backend.pause();
    }
  }

  Future<void> resume(AccountKey account) async {
    final backend = _backends[account];
    if (backend == null) {
      await start(account);
      return;
    }
    await _startBackend(backend);
    _activeKey = account;
    _activeController.add(account);
  }

  Future<void> setGhostMode(bool enabled) async {
    _requireAlive();
    _ghostMode = enabled;
    for (final backend in _backends.values) {
      if (backend.state != BackendState.paused) {
        await backend.setGhostMode(enabled);
      }
    }
  }

  Future<bool> removeAccount(
    AccountKey account, {
    required CredentialStore credentials,
    required AccountSpoofStoreBridge spoofBridge,
  }) async {
    _requireAlive();
    final backend = _backends.remove(account);
    if (backend != null) await backend.dispose();
    if (_activeKey == account) {
      _activeKey = null;
      _activeController.add(null);
    }
    final removed = await credentials.deleteAccountCredentials(account);
    final spoofRemoved = await spoofBridge.remove(account);
    return removed || spoofRemoved;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final backend in _backends.values) await backend.dispose();
    _backends.clear();
    await _activeController.close();
  }

  void _requireAlive() {
    if (_disposed) throw StateError('SessionManager: disposed');
  }
}

typedef MessengerBackendFactory = MessengerBackend Function(AccountKey account);
