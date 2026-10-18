/// Read-only unified chat list assembled from the available account backends.
library;

import 'dart:async';

import '../backends/messenger_backend.dart';
import '../models/unified/unified_chat.dart';
import 'chat_list_source.dart';

class ChatListAggregator implements ChatListSource {
  final List<MessengerBackend> _backends;
  final Map<String, UnifiedChat> _chats = {};
  final StreamController<List<UnifiedChat>> _controller =
      StreamController<List<UnifiedChat>>.broadcast();
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  ChatListAggregator(this._backends);

  @override
  Stream<List<UnifiedChat>> get chatListStream => _controller.stream;

  void start() {
    for (final backend in _backends) {
      _subscriptions.add(backend.events.listen((_) => _refreshBackend(backend)));
      _refreshBackend(backend);
    }
  }

  Future<void> _refreshBackend(MessengerBackend backend) async {
    final chats = await backend.chats();
    _chats.removeWhere((key, chat) => chat.account == backend.account);
    for (final chat in chats) {
      _chats[_key(chat)] = chat;
    }
    _publish();
  }

  String _key(UnifiedChat chat) => '${chat.account.storageId}/${chat.id}';

  List<UnifiedChat> _sorted() => _chats.values.toList()
    ..sort((a, b) {
      final time = b.lastEventTime.compareTo(a.lastEventTime);
      return time != 0 ? time : _key(a).compareTo(_key(b));
    });

  void _publish() {
    if (!_controller.isClosed) _controller.add(_sorted());
  }

  @override
  List<UnifiedChat> snapshot() => List.unmodifiable(_sorted());

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _controller.close();
  }
}
