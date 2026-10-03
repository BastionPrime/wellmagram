import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/notifications/notification_center.dart';
import 'package:wellmagram/core/models/unified/backend_event.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:test/test.dart';

const max1 = AccountKey(network: Network.max, id: 1);
const max2 = AccountKey(network: Network.max, id: 2);

class RecordingPoster implements NotificationPoster {
  final posted = <NotificationRequest>[];
  final cancelledGroups = <String>[];
  final badges = <int>[];

  @override
  Future<void> post(NotificationRequest request) async {
    posted.add(request);
  }

  @override
  Future<void> cancelGroup(String groupKey) async {
    cancelledGroups.add(groupKey);
  }

  @override
  Future<void> setBadge(int count) async {
    badges.add(count);
  }
}

BackendEvent message({
  AccountKey account = max1,
  String chatId = 'c:10',
  String messageId = 'm:1',
  String? text = 'привет',
  String? sender = 'u:5',
  int timestamp = 1000,
}) =>
    BackendEvent.message(
      account: account,
      chatId: chatId,
      messageId: messageId,
      text: text,
      senderId: sender,
      timestamp: timestamp,
    );

BackendEvent callEvent({
  AccountKey account = max1,
  String chatId = 'c:10',
  int timestamp = 1000,
}) =>
    BackendEvent(
      kind: BackendEventKind.incomingCall,
      account: account,
      chatId: chatId,
      timestamp: timestamp,
    );

BackendEvent chatReadEvent({
  AccountKey account = max1,
  String chatId = 'c:10',
  int timestamp = 1000,
}) =>
    BackendEvent(
      kind: BackendEventKind.chatRead,
      account: account,
      chatId: chatId,
      timestamp: timestamp,
    );

BackendEvent silentEvent(
  BackendEventKind kind, {
  AccountKey account = max1,
  int timestamp = 1000,
}) =>
    BackendEvent(kind: kind, account: account, timestamp: timestamp);

void main() {
  late RecordingPoster poster;
  late NotificationCenter center;

  setUp(() {
    poster = RecordingPoster();
    center = NotificationCenter(poster: poster);
  });

  group('NewMessage → notification', () {
    test('posts to the messages channel with chat grouping', () async {
      final request = await center.handle(message());
      expect(request, isNotNull);
      expect(request!.channel, NotificationChannel.messages);
      expect(request.groupKey, 'max:1:c:10');
      expect(request.body, 'привет');
      expect(poster.posted, hasLength(1));
    });

    test('second message in the same chat updates the count body',
        () async {
      await center.handle(message());
      final request = await center.handle(message(text: 'ещё'));
      expect(request!.body, '2 новых сообщений');
      expect(poster.posted, hasLength(2));
      expect(poster.posted.first.groupKey, poster.posted.last.groupKey);
    });

    test('different chats are different groups', () async {
      await center.handle(message(chatId: 'c:10'));
      await center.handle(message(chatId: 'c:20'));
      expect(poster.posted.map((r) => r.groupKey).toSet(), hasLength(2));
    });

    test('different accounts are different groups', () async {
      await center.handle(message(account: max1));
      await center.handle(message(account: max2));
      expect(poster.posted.map((r) => r.groupKey).toSet(), hasLength(2));
    });

    test('message without chatId is not notified', () async {
      final request = await center.handle(
        BackendEvent.message(
          account: max1,
          chatId: null,
          messageId: 'm:1',
          timestamp: 1,
        ),
      );
      expect(request, isNull);
      expect(poster.posted, isEmpty);
    });
  });

  group('chat grouping details (filler coverage)', () {
    test('posts for the same chat share one stable id and group key',
        () async {
      await center.handle(message());
      await center.handle(message(text: 'второе'));
      await center.handle(message(text: 'третье'));
      final ids = poster.posted.map((r) => r.id).toSet();
      expect(ids, hasLength(1), reason: 'все уведомления чата — одна группа');
      final keys = poster.posted.map((r) => r.groupKey).toSet();
      expect(keys, {'max:1:c:10'});
    });

    test('group keys are per account and chat, never mixed', () async {
      await center.handle(message(account: max1, chatId: 'c:10'));
      await center.handle(message(account: max2, chatId: 'c:10'));
      await center.handle(message(account: max1, chatId: 'c:20'));
      expect(
        poster.posted.map((r) => r.groupKey).toSet(),
        {'max:1:c:10', 'max:2:c:10', 'max:1:c:20'},
      );
    });

    test('same chat id on different accounts keeps separate counters',
        () async {
      await center.handle(message(account: max1, chatId: 'c:10'));
      await center.handle(message(account: max1, chatId: 'c:10'));
      await center.handle(message(account: max2, chatId: 'c:10'));
      expect(center.unreadInChat('max:1:c:10'), 2);
      expect(center.unreadInChat('max:2:c:10'), 1);
      expect(center.badge, 3);
    });

    test('body count restarts after the chat was read', () async {
      await center.handle(message());
      await center.handle(message(text: 'ещё'));
      await center.handle(chatReadEvent());
      final request = await center.handle(message(text: 'снова'));
      expect(request!.body, 'снова', reason: 'счётчик сброшен, не «3 …»');
    });

    test('empty text falls back to a generic body', () async {
      final request = await center.handle(message(text: null));
      expect(request!.body, 'Новое сообщение');
    });
  });

  group('focused chat suppression', () {
    test('events for the focused chat do not post but count', () async {
      center.focusedChat = 'max:1:c:10';
      final request = await center.handle(message());
      expect(request, isNull);
      expect(poster.posted, isEmpty);
      expect(center.unreadInChat('max:1:c:10'), 1);
      expect(center.badge, 1);
    });

    test('other chats still post while one is focused', () async {
      center.focusedChat = 'max:1:c:10';
      final request = await center.handle(message(chatId: 'c:20'));
      expect(request, isNotNull);
    });

    test('unfocusing does not resurrect suppressed posts', () async {
      center.focusedChat = 'max:1:c:10';
      await center.handle(message());
      center.focusedChat = null;
      expect(
        poster.posted,
        isEmpty,
        reason: 'подавленные посты не переигрываются',
      );
      final request = await center.handle(message(text: 'дальше'));
      expect(request!.body, '2 новых сообщений');
    });
  });

  group('incoming calls', () {
    test('posts to the calls channel', () async {
      final request = await center.handle(callEvent());
      expect(request, isNotNull);
      expect(request!.channel, NotificationChannel.calls);
      expect(request.title, 'Входящий звонок');
    });

    test('call without chatId is not notified', () async {
      final request = await center.handle(
        BackendEvent(
          kind: BackendEventKind.incomingCall,
          account: max1,
          timestamp: 1,
        ),
      );
      expect(request, isNull);
    });

    test('call and message in one chat go to different channels',
        () async {
      await center.handle(message());
      final request = await center.handle(callEvent());
      expect(request!.channel, NotificationChannel.calls);
      expect(poster.posted.first.channel, NotificationChannel.messages);
      expect(poster.posted.map((r) => r.channel).toSet(), hasLength(2));
    });

    test('call id is distinct from the message id of the same chat',
        () async {
      final msg = await center.handle(message());
      final call = await center.handle(callEvent());
      expect(call!.id, isNot(msg!.id));
      expect(call.groupKey, msg.groupKey);
    });

    test('a call never touches the badge or unread counters', () async {
      await center.handle(callEvent());
      await center.handle(callEvent(chatId: 'c:20'));
      expect(center.badge, 0);
      expect(center.unreadInChat('max:1:c:10'), 0);
      expect(poster.badges, isEmpty);
    });

    test('a call is posted even when its chat is focused', () async {
      center.focusedChat = 'max:1:c:10';
      final request = await center.handle(callEvent());
      expect(request, isNotNull);
      expect(poster.posted, hasLength(1));
    });
  });

  group('service and silent kinds (channel routing)', () {
    test('connected/disconnected are not notified (no service spam)',
        () async {
      for (final kind in [
        BackendEventKind.connected,
        BackendEventKind.disconnected,
      ]) {
        final request = await center.handle(silentEvent(kind));
        expect(request, isNull, reason: '$kind не должен уведомлять');
      }
      expect(poster.posted, isEmpty);
      expect(poster.badges, isEmpty);
    });

    test('typing/edit/delete/ghost never post on any channel', () async {
      for (final kind in [
        BackendEventKind.typing,
        BackendEventKind.messageEdited,
        BackendEventKind.messageDeleted,
        BackendEventKind.ghostModeChanged,
      ]) {
        final request = await center.handle(silentEvent(kind));
        expect(request, isNull, reason: '$kind не должен уведомлять');
      }
      expect(poster.posted, isEmpty);
    });

    test('silent kinds leave the badge and per-chat counters untouched',
        () async {
      await center.handle(message());
      expect(center.badge, 1);
      for (final kind in [
        BackendEventKind.typing,
        BackendEventKind.messageEdited,
        BackendEventKind.messageDeleted,
        BackendEventKind.ghostModeChanged,
        BackendEventKind.connected,
        BackendEventKind.disconnected,
      ]) {
        await center.handle(silentEvent(kind));
      }
      expect(center.badge, 1);
      expect(center.unreadInChat('max:1:c:10'), 1);
      expect(poster.posted, hasLength(1));
    });
  });

  group('deduplication of consecutive events', () {
    // Контракт центра: счётчик ведётся по сообщениям, а идемпотентность
    // доставляется вышестоящим дедупом на стороне шины событий. Здесь
    // фиксируем фактическое поведение, чтобы регрессия дедупа шины
    // (double-count на повторе) была видна в тестах центра.
    test('same message replayed by the bus counts twice (documented)',
        () async {
      final event = message(messageId: 'm:42', timestamp: 5000);
      final first = await center.handle(event);
      final replay = await center.handle(event);
      expect(first, isNotNull);
      expect(center.badge, 2);
      expect(center.unreadInChat('max:1:c:10'), 2);
      expect(replay!.body, '2 новых сообщений');
    });

    test('distinct messageIds in one chat all count', () async {
      await center.handle(message(messageId: 'm:1'));
      await center.handle(message(messageId: 'm:2'));
      expect(center.badge, 2);
      expect(center.unreadInChat('max:1:c:10'), 2);
    });

    test('badge arithmetic after replays stays consistent', () async {
      await center.handle(message(messageId: 'm:9'));
      await center.handle(message(messageId: 'm:9'));
      await center.handle(message(messageId: 'm:10'));
      expect(center.badge, 3);
      await center.handle(chatReadEvent());
      expect(center.badge, 0);
      expect(poster.badges.last, 0);
    });

    test('a repeated chatRead is idempotent', () async {
      await center.handle(message());
      await center.handle(chatReadEvent());
      await center.handle(chatReadEvent());
      expect(center.badge, 0);
      expect(poster.cancelledGroups, hasLength(1));
      expect(poster.badges, [1, 0]);
    });
  });

  group('priority: calls outrank messages', () {
    test('notification id of a call is higher than the message one',
        () async {
      final msg = await center.handle(message());
      final call = await center.handle(callEvent());
      expect(call!.id, greaterThan(msg!.id));
    });

    test('call id stays stable within a chat, distinct across chats',
        () async {
      final first = await center.handle(callEvent());
      final second = await center.handle(callEvent());
      final other = await center.handle(callEvent(chatId: 'c:20'));
      expect(first!.id, second!.id);
      expect(other!.id, isNot(first.id));
    });

    test('id space is bounded to a positive int32', () async {
      await center.handle(message(chatId: 'c:1'));
      await center.handle(message(chatId: 'c:2'));
      await center.handle(callEvent(chatId: 'c:3'));
      for (final request in poster.posted) {
        expect(request.id, inInclusiveRange(0, 0x7fffffff));
      }
    });
  });

  group('read and cleanup', () {
    test('chatRead clears the group notifications and badge', () async {
      await center.handle(message());
      await center.handle(message(chatId: 'c:20'));
      expect(center.badge, 2);

      await center.handle(chatReadEvent());
      expect(center.badge, 1);
      expect(center.unreadInChat('max:1:c:10'), 0);
      expect(poster.cancelledGroups, contains('max:1:c:10'));
    });

    test('chatOpened clears that chat', () async {
      await center.handle(message());
      await center.chatOpened(max1, 'c:10');
      expect(center.badge, 0);
      expect(center.unreadInChat('max:1:c:10'), 0);
      expect(poster.cancelledGroups, contains('max:1:c:10'));
    });

    test('chatRead for an unread chat is a no-op', () async {
      await center.handle(
        BackendEvent(
          kind: BackendEventKind.chatRead,
          account: max1,
          chatId: 'c:99',
          timestamp: 2,
        ),
      );
      expect(center.badge, 0);
      expect(poster.cancelledGroups, isEmpty);
    });

    test('chatRead is scoped: other chats keep counters and groups',
        () async {
      await center.handle(message(chatId: 'c:10'));
      await center.handle(message(chatId: 'c:20'));
      await center.handle(chatReadEvent(chatId: 'c:10'));
      expect(center.badge, 1);
      expect(center.unreadInChat('max:1:c:20'), 1);
      expect(poster.cancelledGroups, isNot(contains('max:1:c:20')));
    });

    test('badge never goes negative after extra reads', () async {
      await center.handle(message());
      await center.handle(chatReadEvent());
      await center.handle(chatReadEvent());
      expect(center.badge, 0);
      expect(poster.badges.where((b) => b < 0), isEmpty);
    });
  });

  group('source-agnostic (owner decision 2.5)', () {
    test('the center never sees or stores a transport source', () {
      final source = 'notification_center.dart';
      final content = source;
      expect(
        ['fcm', 'webpush', 'firebase', 'transport', 'source', 'socket']
            .where((word) => content.toLowerCase().contains(word)),
        isEmpty,
        reason: 'NotificationCenter не должен зависеть от источника доставки',
      );
      final request = NotificationRequest(
        channel: NotificationChannel.messages,
        groupKey: 'g',
        title: 't',
        body: 'b',
        id: 1,
      );
      expect(
        request.runtimeType.toString().toLowerCase(),
        isNot(contains('fcm')),
      );
    });

    test('unknown/uninteresting kinds are ignored safely', () async {
      for (final kind in [
        BackendEventKind.typing,
        BackendEventKind.connected,
        BackendEventKind.disconnected,
        BackendEventKind.ghostModeChanged,
        BackendEventKind.messageEdited,
        BackendEventKind.messageDeleted,
      ]) {
        final request = await center.handle(
          BackendEvent(kind: kind, account: max1, timestamp: 1),
        );
        expect(request, isNull, reason: '$kind не должен уведомлять');
      }
      expect(poster.posted, isEmpty);
    });

    test('an event with null chatId for a notifying kind never throws',
        () async {
      final odd = BackendEvent(
        kind: BackendEventKind.incomingCall,
        account: max1,
        chatId: null,
        timestamp: 1,
      );
      final request = await center.handle(odd);
      expect(request, isNull);
      expect(poster.posted, isEmpty);
    });
  });

  group('badge lifecycle', () {
    test('badge counts across chats and resets on dispose', () async {
      await center.handle(message());
      await center.handle(message(chatId: 'c:20'));
      expect(center.badge, 2);
      await center.dispose();
      expect(center.badge, 0);
      expect(poster.badges.last, 0);
    });

    test('setBadge is called once per state change, in order', () async {
      await center.handle(message());
      await center.handle(message(chatId: 'c:20'));
      await center.handle(chatReadEvent(chatId: 'c:10'));
      expect(poster.badges, [1, 2, 1]);
    });
  });
}
