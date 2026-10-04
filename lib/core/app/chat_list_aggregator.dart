import 'dart:async';
import 'package:rxdart/rxdart.dart';

import '../models/unified/unified_chat.dart';
import '../models/unified/backend_event.dart';
import '../backends/messenger_backend.dart';

/// Агрегирует списки чатов из разных бэкендов в один единый список,
/// сортированный по времени последнего сообщения.
class ChatListAggregator {
  final List<MessengerBackend> _backends;
  final Map<String, UnifiedChat> _chats = {};
  final BehaviorSubject<List<UnifiedChat>> _chatListSubject;

  Stream<List<UnifiedChat>> get chatListStream => _chatListSubject.stream;

  ChatListAggregator(this._backends) : _chatListSubject = BehaviorSubject.seeded([]);

  /// Подписывается на события всех бэкендов и начинает агрегацию
  void start() {
    for (final backend in _backends) {
      backend.backendEvents.listen(_handleBackendEvent);
    }
  }

  /// Обрабатывает события от бэкендов
  void _handleBackendEvent(BackendEvent event) {
    switch (event.type) {
      case BackendEventType.chatAdded:
        if (event.chat != null) {
          _chats[event.chat!.id] = event.chat!;
          _updateChatList();
        }
        break;
      case BackendEventType.chatUpdated:
        if (event.chat != null && _chats.containsKey(event.chat!.id)) {
          // Обновляем существующий чат
          _chats[event.chat!.id] = event.chat!;
          _updateChatList();
        }
        break;
      case BackendEventType.chatRemoved:
        if (event.chat != null) {
          _chats.remove(event.chat!.id);
          _updateChatList();
        }
        break;
      case BackendEventType.messageReceived:
        // Обновляем lastMessageTime для соответствующего чата
        if (event.chatId != null && _chats.containsKey(event.chatId!)) {
          final chat = _chats[event.chatId!]!;
          if (event.timestamp != null) {
            // Создаем обновленный чат с новым временем последнего сообщения
            final updatedChat = UnifiedChat(
              id: chat.id,
              title: chat.title,
              lastMessage: event.message ?? chat.lastMessage,
              lastMessageTime: event.timestamp!,
              unreadCount: event.unreadCount ?? chat.unreadCount,
              isMuted: chat.isMuted,
              avatarUrl: chat.avatarUrl,
              type: chat.type,
              backendType: chat.backendType,
            );
            _chats[event.chatId!] = updatedChat;
            _updateChatList();
          }
        }
        break;
      default:
        // Игнорируем другие типы событий
        break;
    }
  }

  /// Обновляет список чатов и отправляет его подписчикам
  void _updateChatList() {
    final chats = _chats.values.toList();
    
    // Сортировка по времени последнего сообщения (по убыванию), 
    // с дополнительной сортировкой по ID для стабильности порядка
    chats.sort((a, b) {
      // Сначала сравниваем по времени последнего сообщения
      final timeCompare = (b.lastMessageTime?.compareTo(a.lastMessageTime ?? 0) ?? 0);
      if (timeCompare != 0) {
        return timeCompare;
      }
      // Если время одинаковое, используем ID для стабильности
      return a.id.compareTo(b.id);
    });

    _chatListSubject.add(chats);
  }

  /// Возвращает актуальный снимок списка чатов для быстрой загрузки
  List<UnifiedChat> snapshot() {
    return _chats.values.toList()
      ..sort((a, b) {
        final timeCompare = (b.lastMessageTime?.compareTo(a.lastMessageTime ?? 0) ?? 0);
        if (timeCompare != 0) {
          return timeCompare;
        }
        return a.id.compareTo(b.id);
      });
  }

  /// Останавливает агрегацию и освобождает ресурсы
  void dispose() {
    _chatListSubject.close();
  }
}
