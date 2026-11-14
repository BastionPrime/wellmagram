/// Telegram adapter implementing the shared MessengerBackend contract.
library;

import 'dart:async';

import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/backends/capabilities.dart';
import 'package:wellmagram/core/backends/messenger_backend.dart';
import 'package:wellmagram/core/backends/telegram/td_ghost.dart';
import 'package:wellmagram/core/backends/telegram/td_chat_store.dart';
import 'package:wellmagram/core/backends/telegram/td_media.dart';
import 'package:wellmagram/core/backends/telegram/td_push.dart';
import 'package:wellmagram/core/backends/telegram/td_messages.dart';
import 'package:wellmagram/core/backends/telegram/td_sessions.dart';
import 'package:wellmagram/core/models/unified/backend_event.dart';
import 'package:wellmagram/core/models/unified/unified_chat.dart';

/// Thin backend facade over one [TdLiveSession]. Session lifecycle remains in
/// [TdSessionManager], while the app layer sees the same contract as MAX.
class TelegramBackend implements MessengerBackend {
  final AccountKey _account;
  final TdLiveSession _session;
  final TdMessages _messages;
  final TdChatStore _chatStore;
  final TdMedia _media;
  final TdPush _push;
  final _events = StreamController<BackendEvent>.broadcast();
  final _states = StreamController<BackendState>.broadcast();
  late final StreamSubscription<Map<String, dynamic>> _updates;
  bool _disposed = false;
  bool _paused = false;

  TelegramBackend({required AccountKey account, required TdLiveSession session})
      : _account = account,
        _session = session,
        _messages = TdMessages(bridge: session.bridge),
        _chatStore = TdChatStore(bridge: session.bridge, account: account),
        _media = TdMedia(bridge: session.bridge),
        _push = TdPush(bridge: session.bridge) {
    _updates = _session.bridge.updates.listen(_onUpdate);
  }

  @override
  AccountKey get account => _account;

  @override
  Capabilities get capabilities => Capabilities.telegram;

  @override
  BackendState get state => _paused
      ? BackendState.paused
      : (_disposed ? BackendState.disconnected : BackendState.online);

  @override
  Stream<BackendEvent> get events => _events.stream;

  @override
  Stream<BackendState> get stateChanges => _states.stream;

  @override
  Future<List<UnifiedChat>> chats() async {
    await _chatStore.loadChats();
    return _chatStore.views;
  }

  @override
  Future<List<UnifiedMessage>> history(String chatId, {int limit = 50}) =>
      _chatStore.history(tgParseChatId(chatId), limit: limit);

  @override
  Future<SendResult> sendText(String chatId, String text) async {
    _requireActive();
    final result = await _messages.sendText(tgParseChatId(chatId), text);
    return SendResult(messageId: result.messageId, timestamp: result.timestamp);
  }

  @override
  Future<void> sendMedia(String chatId, String filePath) =>
      throw UnsupportedError('TelegramBackend.sendMedia: media adapter pending');

  @override
  Future<void> editText(String chatId, String messageId, String newText) async {
    _requireActive();
    await _messages.editText(
      tgParseChatId(chatId),
      tgParseMessageId(messageId),
      newText,
    );
  }

  @override
  Future<void> deleteMessages(String chatId, List<String> messageIds) =>
      _messages.deleteMessages(
        tgParseChatId(chatId),
        messageIds.map(tgParseMessageId).toList(),
      );

  @override
  Future<void> setReaction(String chatId, String messageId, String reaction) =>
      _messages.addReaction(
        tgParseChatId(chatId),
        tgParseMessageId(messageId),
        reaction,
      );

  @override
  Future<void> markRead(String chatId) => _session.ghost.markRead(
        tgParseChatId(chatId),
        const [],
      );

  @override
  Future<void> setTyping(String chatId, bool typing) => typing
      ? _session.ghost.sendTyping(
          tgParseChatId(chatId),
          const {'@type': 'chatActionTyping'},
        )
      : Future<void>.value();

  @override
  Future<void> downloadMedia(String messageId, String targetPath) async {
    final fileId = tgParseMessageId(messageId);
    final path = await _media.awaitDownloaded(fileId);
    if (path != targetPath) {
      throw StateError('TelegramBackend: downloaded file path differs from target');
    }
  }

  @override
  Future<void> registerPush(String pushToken) async {
    await _push.register(TdPushToken(
      channelId: 'opaque',
      wireForm: () => tdFcmDeviceToken(pushToken),
    ));
  }

  @override
  Future<void> unregisterPush(String pushToken) async {
    await _push.unregister(TdPushToken(
      channelId: 'opaque',
      wireForm: () => tdFcmDeviceToken(pushToken),
    ));
  }

  @override
  Future<void> setGhostMode(bool enabled) => _session.ghost.setGhostMode(
        enabled
            ? const TdGhostSettings()
            : TdGhostSettings.off,
      );

  @override
  Future<void> pause() async {
    _requireActive();
    if (_paused) return;
    _paused = true;
    _states.add(BackendState.paused);
  }

  @override
  Future<void> resume() async {
    _requireNotDisposed();
    if (!_paused) return;
    _paused = false;
    await _session.ghost.reapplyOnline();
    _states.add(BackendState.online);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _updates.cancel();
    await _events.close();
    await _states.close();
  }

  void _onUpdate(Map<String, dynamic> update) {
    if (update['@type'] == 'updateNewChat') {
      final chat = update['chat'];
      if (chat is Map) _chatStore.ingest(chat.cast<String, dynamic>());
    }
    if (update['@type'] == 'updateNewMessage' && !_events.isClosed) {
      _events.add(BackendEvent(
        kind: BackendEventKind.newMessage,
        account: _account,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ));
    }
  }

  void _requireNotDisposed() {
    if (_disposed) throw StateError('TelegramBackend: disposed');
  }

  void _requireActive() {
    _requireNotDisposed();
    if (_paused) throw StateError('TelegramBackend: paused');
  }
}
