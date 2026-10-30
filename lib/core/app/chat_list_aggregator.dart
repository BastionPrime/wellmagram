/// ChatListAggregator (plan OPE-2270 T-3.1).
///
/// Merges chat streams and updates across messenger backends into a single
/// unified chat list, sorted by lastEventTime descending with tie-breaking by id.
library;

import 'dart:async';

import '../accounts/account_key.dart';
import '../backends/messenger_backend.dart';
import '../models/unified/backend_event.dart';
import '../models/unified/unified_chat.dart';

class ChatListAggregator {
  final List<MessengerBackend> _backends;
  final Map<String, UnifiedChat> _chats = {};
  final StreamController<List<UnifiedChat>> _controller =
      StreamController<List<UnifiedChat>>.broadcast();
  final List<StreamSubscription<BackendEvent>> _subscriptions = [];

  ChatListAggregator(this._backends);

  static String _chatKey(AccountKey account, String id) =>
      '${account.network.name}:${account.id}:$id';

  /// Stream of sorted chat list updates emitted whenever chats change.
  Stream<List<UnifiedChat>> get chatListStream => _controller.stream;

  /// Adds or updates a chat in the in-memory aggregated model.
  void addChat(UnifiedChat chat) {
    _chats[_chatKey(chat.account, chat.id)] = chat;
    _emit();
  }

  /// Ingests an initial or updated chat (alias for [addChat]).
  void ingest(UnifiedChat chat) => addChat(chat);

  /// Subscribes to events from all backends and begins aggregation.
  void start() {
    for (final backend in _backends) {
      _subscriptions.add(backend.events.listen(_handleBackendEvent));
    }
  }

  void _handleBackendEvent(BackendEvent event) {
    final chatId = event.chatId;
    if (chatId == null) {
      // Event without chat is ignored.
      return;
    }

    final key = _chatKey(event.account, chatId);
    final existing = _chats[key];
    if (existing == null) {
      // Event for an unknown chat is ignored.
      return;
    }

    final updated = applyEventToChat(existing, event);
    if (updated != existing) {
      _chats[key] = updated;
      _emit();
    }
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(snapshot());
    }
  }

  /// Returns a deterministic snapshot of the chat list for cold starts.
  ///
  /// Sorted descending by [UnifiedChat.lastEventTime], then ascending by [UnifiedChat.id].
  List<UnifiedChat> snapshot() {
    final list = _chats.values.toList();
    list.sort((a, b) {
      final timeCmp = b.lastEventTime.compareTo(a.lastEventTime);
      if (timeCmp != 0) return timeCmp;
      return a.id.compareTo(b.id);
    });
    return list;
  }

  /// Cancels all event subscriptions and closes the stream.
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _controller.close();
  }
}
