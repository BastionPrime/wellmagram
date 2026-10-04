import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';

import 'package:wellmagram/core/app/chat_list_aggregator.dart';
import 'package:wellmagram/core/models/unified/unified_chat.dart';
import 'package:wellmagram/core/models/unified/backend_event.dart';
import 'package:wellmagram/core/backends/messenger_backend.dart';

void main() {
  group('ChatListAggregator Tests', () {
    late MockMessengerBackend mockBackend1;
    late MockMessengerBackend mockBackend2;
    late ChatListAggregator aggregator;

    setUp(() {
      mockBackend1 = MockMessengerBackend();
      mockBackend2 = MockMessengerBackend();
      aggregator = ChatListAggregator([mockBackend1, mockBackend2]);
      aggregator.start();
    });

    tearDown(() {
      aggregator.dispose();
    });

    test('Merge two networks - combines chats from both backends', () async {
      // Подготовим чаты от разных бэкендов
      final chat1 = UnifiedChat(
        id: 'chat1',
        title: 'Chat 1',
        lastMessageTime: 1000,
        backendType: 'MAX',
      );
      
      final chat2 = UnifiedChat(
        id: 'chat2',
        title: 'Chat 2',
        lastMessageTime: 2000,
        backendType: 'TG',
      );

      // Отправим события добавления чатов
      mockBackend1.addEvent(BackendEvent(
        type: BackendEventType.chatAdded,
        chat: chat1,
      ));
      
      mockBackend2.addEvent(BackendEvent(
        type: BackendEventType.chatAdded,
        chat: chat2,
      ));

      // Проверим, что оба чата присутствуют в агрегированном списке
      await expectLater(
        aggregator.chatListStream,
        emitsInOrder([
          // Первый emit - пустой список из BehaviorSubject.seeded([])
          [],
          // Второй emit - после первого добавления
          [chat1],
          // Третий emit - после второго добавления
          [chat2, chat1], // Сортировка по времени (chat2 имеет более позднее время)
        ]),
      );
    });

    test('Update lastMessage moves position in sorted list', () async {
      final earlyChat = UnifiedChat(
        id: 'early',
        title: 'Early Chat',
        lastMessageTime: 1000,
      );
      
      final lateChat = UnifiedChat(
        id: 'late',
        title: 'Late Chat',
        lastMessageTime: 2000,
      );

      // Добавим оба чата
      mockBackend1.addEvent(BackendEvent(
        type: BackendEventType.chatAdded,
        chat: earlyChat,
      ));
      
      mockBackend1.addEvent(BackendEvent(
        type: BackendEventType.chatAdded,
        chat: lateChat,
      ));

      // Обновим время последнего сообщения для раннего чата, чтобы оно стало позже
      final updatedEarlyChat = UnifiedChat(
        id: 'early',
        title: 'Early Chat',
        lastMessageTime: 3000, // Больше, чем у lateChat
      );

      mockBackend1.addEvent(BackendEvent(
        type: BackendEventType.chatUpdated,
        chat: updatedEarlyChat,
      ));

      // Проверим, что теперь ранний чат находится первым в списке
      await expectLater(
        aggregator.chatListStream,
        emitsInOrder([
          [], // начальное состояние
          [earlyChat], // первый чат
          [lateChat, earlyChat], // второй чат добавлен, сортировка: lateChat(2000), earlyChat(1000)
          [earlyChat, lateChat], // после обновления: earlyChat(3000), lateChat(2000)
        ]),
      );
    });

    test('Event without chat is ignored', () async {
      // Отправим событие без чата
      mockBackend1.addEvent(BackendEvent(
        type: BackendEventType.messageReceived,
        chatId: 'nonexistent',
        timestamp: 1000,
      ));

      // Проверим, что список не изменился
      await expectLater(
        aggregator.chatListStream,
        emitsInOrder([
          [], // начальное состояние
          []  // остается пустым, поскольку событие без чата проигнорировано
        ]),
      );
    });

    test('Snapshot is deterministic', () {
      final chat1 = UnifiedChat(
        id: 'chat1',
        title: 'Chat 1',
        lastMessageTime: 1000,
      );
      
      final chat2 = UnifiedChat(
        id: 'chat2',
        title: 'Chat 2',
        lastMessageTime: 1000, // То же время, чтобы проверить стабильность сортировки по ID
      );

      // Добавим чаты
      mockBackend1.addEvent(BackendEvent(
        type: BackendEventType.chatAdded,
        chat: chat1,
      ));
      
      mockBackend1.addEvent(BackendEvent(
        type: BackendEventType.chatAdded,
        chat: chat2,
      ));

      // Получим несколько снимков
      final snapshot1 = aggregator.snapshot();
      final snapshot2 = aggregator.snapshot();

      // Проверим, что снимки идентичны
      expect(snapshot1.length, equals(2));
      expect(snapshot2.length, equals(2));
      expect(snapshot1, equals(snapshot2));

      // Проверим сортировку (должна быть по времени, затем по ID)
      // Поскольку время одинаковое, сортировка будет по ID
      expect(snapshot1[0].id, equals('chat1'));
      expect(snapshot1[1].id, equals('chat2'));
    });
  });
}

// Мок-класс для имитации MessengerBackend
class MockMessengerBackend implements MessengerBackend {
  final BehaviorSubject<BackendEvent> _eventController = BehaviorSubject<BackendEvent>();

  @override
  Stream<BackendEvent> get backendEvents => _eventController.stream;

  void addEvent(BackendEvent event) {
    _eventController.add(event);
  }

  @override
  String get backendId => 'mock_backend';

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {
    _eventController.close();
  }

  @override
  Future<List<UnifiedChat>> getChatList() async => [];

  @override
  Future<void> sendMessage(String chatId, String message) async {}
}
