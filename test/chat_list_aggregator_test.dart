import 'dart:async';

import 'package:test/test.dart';
import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/app/chat_list_aggregator.dart';
import 'package:wellmagram/core/backends/capabilities.dart';
import 'package:wellmagram/core/backends/messenger_backend.dart';
import 'package:wellmagram/core/models/unified/backend_event.dart';
import 'package:wellmagram/core/models/unified/unified_chat.dart';

void main() {
  const maxAccount = AccountKey(network: Network.max, id: 1);
  const tgAccount = AccountKey(network: Network.telegram, id: 2);

  group('ChatListAggregator', () {
    late MockMessengerBackend mockBackend1;
    late MockMessengerBackend mockBackend2;
    late ChatListAggregator aggregator;

    setUp(() {
      mockBackend1 = MockMessengerBackend(maxAccount);
      mockBackend2 = MockMessengerBackend(tgAccount);
      aggregator = ChatListAggregator([mockBackend1, mockBackend2]);
      aggregator.start();
    });

    tearDown(() {
      aggregator.dispose();
      mockBackend1.dispose();
      mockBackend2.dispose();
    });

    test('Merge two networks - combines chats from both backends', () {
      final chat1 = UnifiedChat(
        account: maxAccount,
        id: 'c:101',
        title: 'Max Chat 1',
        isGroup: false,
        lastEventTime: 1000,
      );
      final chat2 = UnifiedChat(
        account: tgAccount,
        id: 't:202',
        title: 'TG Chat 2',
        isGroup: false,
        lastEventTime: 2000,
      );

      aggregator.addChat(chat1);
      aggregator.addChat(chat2);

      final snapshot = aggregator.snapshot();
      expect(snapshot, equals([chat2, chat1]));
    });

    test('Update lastMessage moves position in sorted list', () async {
      final earlyChat = UnifiedChat(
        account: maxAccount,
        id: 'c:early',
        title: 'Early Chat',
        isGroup: false,
        lastEventTime: 1000,
      );
      final lateChat = UnifiedChat(
        account: maxAccount,
        id: 'c:late',
        title: 'Late Chat',
        isGroup: false,
        lastEventTime: 2000,
      );

      aggregator.addChat(earlyChat);
      aggregator.addChat(lateChat);
      expect(aggregator.snapshot(), equals([lateChat, earlyChat]));

      final futureEmit = aggregator.chatListStream.first;

      mockBackend1.emitEvent(BackendEvent.message(
        account: maxAccount,
        chatId: 'c:early',
        messageId: 'm:99',
        text: 'new message',
        timestamp: 3000,
      ));

      final updatedList = await futureEmit;
      expect(updatedList.first.id, equals('c:early'));
      expect(updatedList.first.lastEventTime, equals(3000));
      expect(updatedList.first.lastMessagePreview, equals('new message'));
      expect(updatedList.first.unreadCount, equals(1));
      expect(updatedList.last.id, equals('c:late'));
    });

    test('Event without chat is ignored', () async {
      final chat = UnifiedChat(
        account: maxAccount,
        id: 'c:existing',
        title: 'Existing Chat',
        isGroup: false,
        lastEventTime: 1000,
      );
      aggregator.addChat(chat);

      // Event with unknown chatId
      mockBackend1.emitEvent(BackendEvent.message(
        account: maxAccount,
        chatId: 'c:unknown',
        messageId: 'm:1',
        text: 'ignored',
        timestamp: 5000,
      ));

      // Event without chatId
      mockBackend1.emitEvent(const BackendEvent(
        kind: BackendEventKind.connected,
        account: maxAccount,
        timestamp: 6000,
      ));

      await Future<void>.delayed(Duration.zero);

      final snapshot = aggregator.snapshot();
      expect(snapshot.length, equals(1));
      expect(snapshot.first.id, equals('c:existing'));
      expect(snapshot.first.lastEventTime, equals(1000));
    });

    test('Snapshot is deterministic', () {
      final chat1 = UnifiedChat(
        account: maxAccount,
        id: 'c:alpha',
        title: 'Alpha Chat',
        isGroup: false,
        lastEventTime: 1000,
      );
      final chat2 = UnifiedChat(
        account: maxAccount,
        id: 'c:beta',
        title: 'Beta Chat',
        isGroup: false,
        lastEventTime: 1000,
      );

      aggregator.addChat(chat2);
      aggregator.addChat(chat1);

      final snapshot1 = aggregator.snapshot();
      final snapshot2 = aggregator.snapshot();

      expect(snapshot1, equals(snapshot2));
      expect(snapshot1.length, equals(2));
      expect(snapshot1[0].id, equals('c:alpha'));
      expect(snapshot1[1].id, equals('c:beta'));
    });
  });
}

class MockMessengerBackend implements MessengerBackend {
  @override
  final AccountKey account;

  final StreamController<BackendEvent> _eventsController =
      StreamController<BackendEvent>.broadcast();

  MockMessengerBackend(this.account);

  @override
  Stream<BackendEvent> get events => _eventsController.stream;

  void emitEvent(BackendEvent event) => _eventsController.add(event);

  @override
  Capabilities get capabilities => Capabilities.max;

  @override
  BackendState get state => BackendState.online;

  @override
  Stream<BackendState> get stateChanges => const Stream.empty();

  @override
  Future<List<UnifiedChat>> chats() async => const [];

  @override
  Future<List<UnifiedMessage>> history(String chatId, {int limit = 50}) async =>
      const [];

  @override
  Future<SendResult> sendText(String chatId, String text) async =>
      const SendResult(messageId: 'm:mock', timestamp: 0);

  @override
  Future<void> sendMedia(String chatId, String filePath) async {}

  @override
  Future<void> editText(
          String chatId, String messageId, String newText) async {}

  @override
  Future<void> deleteMessages(
          String chatId, List<String> messageIds) async {}

  @override
  Future<void> setReaction(
          String chatId, String messageId, String reaction) async {}

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
  Future<void> setGhostMode(bool enabled) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> dispose() async {
    await _eventsController.close();
  }
}
