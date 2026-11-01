/// Behavioral coverage for the unified SessionManager across both networks:
/// MAX and Telegram backends orchestrated by AccountKey in switch/parallel
/// modes (OPE-7910 acceptance), ghost-mode applied to both, MAX↔TG
/// switching, and TelegramBackend's adapter contract.
library;

import 'dart:async';

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/app/session_manager.dart';
import 'package:wellmagram/core/backends/capabilities.dart';
import 'package:wellmagram/core/backends/messenger_backend.dart';
import 'package:wellmagram/core/backends/telegram/td_bridge.dart';
import 'package:wellmagram/core/backends/telegram/td_ghost.dart';
import 'package:wellmagram/core/backends/telegram/td_sessions.dart';
import 'package:wellmagram/core/backends/telegram/telegram_backend.dart';
import 'package:wellmagram/core/models/unified/backend_event.dart';
import 'package:wellmagram/core/models/unified/unified_chat.dart';
import 'package:test/test.dart';

import 'mock_td_client.dart';

const maxA = AccountKey(network: Network.max, id: 1);
const tgB = AccountKey(network: Network.telegram, id: 2);

/// Records ghost-mode application per backend.
class RecordingBackend implements MessengerBackend {
  @override
  final AccountKey account;

  final List<String> calls;
  final _callsByKind = <String, int>{};
  BackendState _state = BackendState.disconnected;
  bool? lastGhost;

  RecordingBackend(this.account, [this.calls = const []]);

  void _record(String kind) {
    _callsByKind[kind] = (_callsByKind[kind] ?? 0) + 1;
  }

  int count(String kind) => _callsByKind[kind] ?? 0;

  @override
  Capabilities get capabilities => throw UnimplementedError();

  @override
  BackendState get state => _state;

  @override
  Stream<BackendEvent> get events => const Stream.empty();

  @override
  Stream<BackendState> get stateChanges => const Stream.empty();

  @override
  Future<List<UnifiedChat>> chats() async => [];

  @override
  Future<List<UnifiedMessage>> history(String chatId, {int limit = 50}) async => [];

  @override
  Future<SendResult> sendText(String chatId, String text) async =>
      SendResult(messageId: 'x', timestamp: 0);

  @override
  Future<void> sendMedia(String chatId, String filePath) async {}

  @override
  Future<void> editText(String chatId, String messageId, String newText) async {}

  @override
  Future<void> deleteMessages(String chatId, List<String> messageIds) async {}

  @override
  Future<void> setReaction(String chatId, String messageId, String reaction) async {}

  @override
  Future<void> markRead(String chatId) async {}

  @override
  Future<void> setTyping(String chatId, bool typing) async {}

  @override
  Future<void> downloadMedia(String messageId, String targetPath) async {}

  @override
  Future<void> registerPush(String pushToken) async {}

  @override
  Future<void> unregisterPush(String pushToken) async {}

  @override
  Future<void> setGhostMode(bool enabled) async {
    _record('ghost');
    lastGhost = enabled;
  }

  @override
  Future<void> pause() async {
    _record('pause');
    _state = BackendState.paused;
  }

  @override
  Future<void> resume() async {
    _record('resume');
    _state = BackendState.online;
  }

  @override
  Future<void> dispose() async {
    _record('dispose');
    _state = BackendState.disconnected;
  }
}

class NetworksHarness {
  final backends = <AccountKey, RecordingBackend>{};
  late final SessionManager manager;

  NetworksHarness(SessionMode mode) {
    manager = SessionManager(mode: mode, factory: (account) {
      final backend = RecordingBackend(account);
      backends[account] = backend;
      return backend;
    });
  }
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  test('switch mode: MAX↔TG switch pauses the previous network session',
      () async {
    final h = NetworksHarness(SessionMode.switchMode);

    final maxBackend = await h.manager.start(maxA);
    await pump();
    expect(maxBackend.state, BackendState.online);
    expect(h.manager.activeKey, maxA);

    final tgBackend = await h.manager.start(tgB);
    await pump();
    expect(tgBackend.state, BackendState.online);
    expect(maxBackend.state, BackendState.paused,
        reason: 'переход MAX→TG должен приостановить MAX-сессию');
    expect(h.manager.activeKey, tgB);

    final backToMax = await h.manager.start(maxA);
    await pump();
    expect(backToMax.state, BackendState.online);
    expect(tgBackend.state, BackendState.paused,
        reason: 'переход TG→MAX должен приостановить TG-сессию');
    expect(h.manager.activeKey, maxA);

    await h.manager.dispose();
  });

  test('parallel mode: MAX and TG sessions stay online simultaneously',
      () async {
    final h = NetworksHarness(SessionMode.parallel);

    final maxBackend = await h.manager.start(maxA);
    final tgBackend = await h.manager.start(tgB);
    await pump();

    expect(maxBackend.state, BackendState.online);
    expect(tgBackend.state, BackendState.online,
        reason: 'в parallel режиме обе сети живут одновременно');
    expect(h.manager.isParallel, isTrue);
    expect(h.manager.activeKey, tgB);
    await h.manager.dispose();
  });

  test('ghost mode is applied to both networks', () async {
    final h = NetworksHarness(SessionMode.parallel);
    await h.manager.setGhostMode(true);

    await h.manager.start(maxA);
    await h.manager.start(tgB);
    await pump();

    expect(h.backends[maxA]!.lastGhost, isTrue,
        reason: 'ghost-режим должен применяться к MAX');
    expect(h.backends[tgB]!.lastGhost, isTrue,
        reason: 'ghost-режим должен применяться к TG');
    expect(h.manager.isGhostMode, isTrue);
    await h.manager.dispose();
  });

  test('one backend per account across networks', () async {
    final h = NetworksHarness(SessionMode.parallel);
    final first = await h.manager.start(maxA);
    await h.manager.start(tgB);
    final again = await h.manager.start(maxA);

    expect(again, same(first));
    expect(h.backends.length, 2);
    await h.manager.dispose();
  });

  group('TelegramBackend adapter', () {
    test('ghost mode delegates to TdGhost with full settings', () async {
      final mock = MockTdClient();
      final bridge = TdBridge(client: mock);
      final ghost = TdGhost(bridge: bridge);
      final session = TdLiveSession(bridge: bridge, ghost: ghost);
      final backend = TelegramBackend(account: tgB, session: session);

      await backend.setGhostMode(true);
      expect(ghost.settings, const TdGhostSettings());

      await backend.setGhostMode(false);
      expect(ghost.settings, TdGhostSettings.off);

      await backend.dispose();
    });

    test('markRead is suppressed while ghost read is on', () async {
      final mock = MockTdClient();
      final bridge = TdBridge(client: mock);
      final ghost = TdGhost(bridge: bridge);
      final session = TdLiveSession(bridge: bridge, ghost: ghost);
      final backend = TelegramBackend(account: tgB, session: session);

      await backend.setGhostMode(true);
      await backend.markRead('t:-1001234567890');

      expect(
        mock.sentRequests.where((r) => r['@type'] == 'openChat'),
        isEmpty,
        reason: 'ghost-read должен подавлять openChat/viewMessages',
      );
      await backend.dispose();
    });

    test('pause/resume emit states and re-apply online ghost', () async {
      final mock = MockTdClient();
      final bridge = TdBridge(client: mock);
      final ghost = TdGhost(bridge: bridge);
      final session = TdLiveSession(bridge: bridge, ghost: ghost);
      final backend = TelegramBackend(account: tgB, session: session);

      final states = <BackendState>[];
      final sub = backend.stateChanges.listen(states.add);

      await backend.pause();
      expect(backend.state, BackendState.paused);

      mock.autoAnswer = true;
      await backend.resume();
      expect(backend.state, BackendState.online);

      expect(states, containsAll([BackendState.paused, BackendState.online]));
      await sub.cancel();
      await backend.dispose();
    });

    test('new message updates surface as backend events', () async {
      final mock = MockTdClient();
      final bridge = TdBridge(client: mock);
      final ghost = TdGhost(bridge: bridge);
      final session = TdLiveSession(bridge: bridge, ghost: ghost);
      final backend = TelegramBackend(account: tgB, session: session);

      final events = <BackendEvent>[];
      final sub = backend.events.listen(events.add);

      mock.emitUpdate({
        '@type': 'updateNewMessage',
        'message': {
          'chat_id': -1001234567890,
          'id': 42,
          'content': {
            '@type': 'messageText',
            'text': {'text': 'hi'},
          },
        },
      });
      await pump();
      await pump();

      expect(events, isNotEmpty,
          reason: 'updateNewMessage должен попадать в общий event stream');
      expect(events.last.account, tgB);
      await sub.cancel();
      await backend.dispose();
    });
  });
}
