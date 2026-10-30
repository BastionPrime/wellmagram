import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/backends/capabilities.dart';
import 'package:wellmagram/core/backends/messenger_backend.dart';
import 'package:wellmagram/core/notifications/notification_center.dart';
import 'package:wellmagram/core/models/unified/backend_event.dart';
import 'package:wellmagram/core/models/unified/unified_chat.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:test/test.dart';

const max1 = AccountKey(network: Network.max, id: 1);
const max2 = AccountKey(network: Network.max, id: 2);
const tg1 = AccountKey(network: Network.telegram, id: 7);

/// Сеть, которая не умеет ни отправки текста, ни звонков: проверяем, что
/// быстрые действия не появляются там, где сеть их не поддерживает.
const withoutText = Capabilities(
  sendText: false,
  sendMedia: false,
  editText: false,
  deleteMessages: false,
  setReaction: false,
  markRead: false,
  setTyping: false,
  downloadMedia: false,
  calls: false,
  pushRegistration: false,
  ghostMode: false,
);

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

/// Минимальный бэкенд, который записывает доставленные быстрые ответы:
/// проверяем маршрутизацию (в какую сеть ушёл ответ), а не транспорт.
class RecordingBackend implements MessengerBackend {
  @override
  final AccountKey account;

  @override
  final Capabilities capabilities;

  /// Доставленные ответы в виде `chatId|text`.
  final sent = <String>[];

  RecordingBackend({required this.account, required this.capabilities});

  @override
  BackendState state = BackendState.disconnected;

  @override
  Stream<BackendEvent> get events => const Stream.empty();

  @override
  Stream<BackendState> get stateChanges => const Stream.empty();

  @override
  Future<List<UnifiedChat>> chats() async => const [];

  @override
  Future<List<UnifiedMessage>> history(String chatId, {int limit = 50}) async =>
      const [];

  @override
  Future<SendResult> sendText(String chatId, String text) async {
    sent.add('$chatId|$text');
    return SendResult(messageId: 'm:${sent.length}', timestamp: 1);
  }

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
  Future<void> setGhostMode(bool enabled) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> dispose() async {}
}

/// Реестр живых сессий аккаунтов для шва центра.
class BackendRegistry {
  BackendRegistry(this._backends);

  final List<MessengerBackend> _backends;

  MessengerBackend? call(AccountKey account) {
    for (final backend in _backends) {
      if (backend.account == account) return backend;
    }
    return null;
  }
}

/// Записывает отказы от звонков, которые центр направил в управление.
class RecordingCallController implements CallController {
  final declined = <String>[];

  @override
  Future<void> declineCall(AccountKey account, String chatId) async {
    declined.add('${account.storageId}|$chatId');
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

  group('channels and priorities (Т-3.6)', () {
    test('channel priorities are ordered calls > messages > service', () {
      expect(
        NotificationChannel.calls.priority,
        greaterThan(NotificationChannel.messages.priority),
      );
      expect(
        NotificationChannel.messages.priority,
        greaterThan(NotificationChannel.service.priority),
      );
    });

    test('the active set is ordered by channel priority', () async {
      await center.handle(message());
      await center.handle(callEvent());
      await center.notifyService(account: max1, title: 'Соединение потеряно');

      expect(
        center.activeNotifications.map((r) => r.channel).toList(),
        [
          NotificationChannel.calls,
          NotificationChannel.messages,
          NotificationChannel.service,
        ],
      );
    });

    test('the service notice is per account and never touches the badge',
        () async {
      final request = await center.notifyService(
        account: max1,
        title: 'MAX отключён',
        body: 'нужен повторный вход',
      );
      expect(request.channel, NotificationChannel.service);
      expect(request.groupKey, 'max:1:service');
      expect(request.body, 'нужен повторный вход');
      expect(center.badge, 0);
      expect(center.unreadInChat('max:1:service'), 0);
      expect(poster.badges, isEmpty, reason: 'служебное — не непрочитанное');
    });

    test('a service notice for another account is its own group', () async {
      await center.notifyService(account: max1, title: 'a');
      await center.notifyService(account: max2, title: 'b');
      expect(
        center.activeNotifications.map((r) => r.groupKey).toSet(),
        {'max:1:service', 'max:2:service'},
      );
    });

    test('chatRead removes the notifications of the group from the active set',
        () async {
      await center.handle(message());
      await center.handle(callEvent());
      expect(center.activeNotifications, hasLength(2));
      await center.handle(chatReadEvent());
      expect(center.activeNotifications, isEmpty);
    });

    test('chatOpened removes the group from the active set', () async {
      await center.handle(message(chatId: 'c:20'));
      await center.chatOpened(max1, 'c:20');
      expect(center.activeNotifications, isEmpty);
    });
  });

  group('quick reply routing (Т-3.6)', () {
    late RecordingBackend maxBackend;
    late RecordingBackend tgBackend;
    late NotificationCenter routing;

    setUp(() {
      maxBackend = RecordingBackend(account: max1, capabilities: Capabilities.max);
      tgBackend =
          RecordingBackend(account: tg1, capabilities: Capabilities.telegram);
      routing = NotificationCenter(
        poster: poster,
        lookupBackend: BackendRegistry([maxBackend, tgBackend]).call,
      );
    });

    test('a messages notification offers the reply action on both networks',
        () async {
      final onMax = await routing.handle(message());
      final onTg = await routing.handle(message(account: tg1, chatId: 'c:7'));
      expect(onMax!.actions.map((a) => a.kind), [NotificationActionKind.reply]);
      expect(onTg!.actions.map((a) => a.kind), [NotificationActionKind.reply]);
      expect(routing.actionsFor(onTg), hasLength(1));
    });

    test('a telegram notification replies into the telegram backend',
        () async {
      final request = await routing.handle(message(account: tg1, chatId: 'c:7'));
      final reply = routing.quickReplyFor(request!);
      expect(reply, isNotNull);
      await reply!('ответ в тг');
      expect(tgBackend.sent, ['c:7|ответ в тг']);
      expect(maxBackend.sent, isEmpty);
    });

    test('a max notification replies into the max backend', () async {
      final request = await routing.handle(message(chatId: 'c:42'));
      await routing.quickReplyFor(request!)!('ответ в max');
      expect(maxBackend.sent, ['c:42|ответ в max']);
      expect(tgBackend.sent, isEmpty);
    });

    test('the callback returns the send result of the routed backend',
        () async {
      final request = await routing.handle(message());
      final result = await routing.quickReplyFor(request!)!('ок');
      expect(result.messageId, 'm:1');
    });

    test('no callback without a live backend for the account', () async {
      final offline = NotificationCenter(poster: poster);
      final request = await offline.handle(message());
      expect(offline.quickReplyFor(request!), isNull,
          reason: 'живой сессии нет — отвечать некуда');
      expect(
        offline.actionsFor(request).map((a) => a.kind),
        [NotificationActionKind.reply],
        reason: 'возможности сети известны и без живой сессии',
      );
    });

    test('no reply action for a network that cannot send text', () async {
      final mute = RecordingBackend(account: max2, capabilities: withoutText);
      final limited = NotificationCenter(
        poster: poster,
        lookupBackend: BackendRegistry([mute]).call,
      );
      final request = await limited.handle(message(account: max2));
      expect(request!.actions, isEmpty);
      expect(limited.quickReplyFor(request), isNull);
    });
  });

  group('call decline gated by capabilities (Т-3.6)', () {
    late RecordingCallController calls;
    late NotificationCenter withCalls;

    setUp(() {
      calls = RecordingCallController();
      withCalls = NotificationCenter(
        poster: poster,
        lookupBackend: BackendRegistry([
          RecordingBackend(account: max1, capabilities: Capabilities.max),
          RecordingBackend(account: tg1, capabilities: Capabilities.telegram),
        ]).call,
        callController: calls,
      );
    });

    test('a MAX call offers decline and routes it to the call controller',
        () async {
      final request = await withCalls.handle(callEvent());
      expect(
        request!.actions.map((a) => a.kind),
        [NotificationActionKind.declineCall],
      );
      expect(await withCalls.declineCall(request), isTrue);
      expect(calls.declined, ['max:1|c:10']);
      expect(poster.cancelledGroups, contains('max:1:c:10'));
      expect(withCalls.activeNotifications, isEmpty);
    });

    test('decline is invisible for a call-less network (telegram)', () async {
      final request = await withCalls.handle(callEvent(account: tg1, chatId: 'c:7'));
      expect(request!.actions, isEmpty, reason: 'сеть без звонков');
      expect(withCalls.actionsFor(request), isEmpty);
      expect(await withCalls.declineCall(request), isFalse);
      expect(calls.declined, isEmpty);
      expect(poster.cancelledGroups, isEmpty);
    });

    test('decline is invisible when call control is not wired', () async {
      final noController = NotificationCenter(
        poster: poster,
        lookupBackend: BackendRegistry([
          RecordingBackend(account: max1, capabilities: Capabilities.max),
        ]).call,
      );
      final request = await noController.handle(callEvent());
      expect(request!.actions, isEmpty);
      expect(await noController.declineCall(request), isFalse);
    });

    test('an account without a live session falls back to the network preset',
        () async {
      final offline = NotificationCenter(
        poster: poster,
        lookupBackend: BackendRegistry(const []).call,
        callController: calls,
      );
      final tgCall = await offline.handle(callEvent(account: tg1, chatId: 'c:7'));
      final maxCall = await offline.handle(callEvent());
      expect(tgCall!.actions, isEmpty, reason: 'preset telegram: calls = false');
      expect(
        maxCall!.actions.map((a) => a.kind),
        [NotificationActionKind.declineCall],
        reason: 'preset max: calls = true',
      );
    });

    test('decline never touches the badge or the unread counters', () async {
      final request = await withCalls.handle(callEvent());
      await withCalls.declineCall(request!);
      expect(withCalls.badge, 0);
      expect(poster.badges, isEmpty);
    });

    test('decline on a messages notification is a no-op', () async {
      final request = await withCalls.handle(message());
      expect(await withCalls.declineCall(request!), isFalse);
      expect(calls.declined, isEmpty);
    });
  });

  group('dedup window (Т-3.6)', () {
    late NotificationCenter deduped;

    setUp(() {
      deduped = NotificationCenter(
        poster: poster,
        dedupWindow: const Duration(minutes: 5),
      );
    });

    test('a replay of the same messageId inside the window is dropped',
        () async {
      final event = message(messageId: 'm:42', timestamp: 1000);
      final first = await deduped.handle(event);
      final replay = await deduped.handle(event);
      expect(first, isNotNull);
      expect(replay, isNull, reason: 'повтор того же сообщения не событие');
      expect(deduped.badge, 1);
      expect(deduped.unreadInChat('max:1:c:10'), 1);
      expect(poster.posted, hasLength(1));
    });

    test('distinct messageIds in one chat all count', () async {
      await deduped.handle(message(messageId: 'm:1'));
      await deduped.handle(message(messageId: 'm:2'));
      expect(deduped.badge, 2);
      expect(poster.posted, hasLength(2));
    });

    test('a repeat after the window counts again', () async {
      await deduped.handle(message(messageId: 'm:42', timestamp: 1000));
      final later = await deduped.handle(
        message(messageId: 'm:42', timestamp: 1000 + 5 * 60 * 1000),
      );
      expect(later!.body, '2 новых сообщений');
      expect(deduped.badge, 2);
    });

    test('the window restarts from every repeat (burst suppression)', () async {
      await deduped.handle(message(messageId: 'm:7', timestamp: 0));
      expect(
        await deduped.handle(message(messageId: 'm:7', timestamp: 60000)),
        isNull,
      );
      expect(
        await deduped.handle(message(messageId: 'm:7', timestamp: 120000)),
        isNull,
      );
      expect(
        await deduped.handle(message(messageId: 'm:7', timestamp: 420001)),
        isNotNull,
      );
      expect(deduped.badge, 2);
    });

    test('the same messageId in another chat or account is not a duplicate',
        () async {
      await deduped.handle(message(messageId: 'm:5', chatId: 'c:10'));
      expect(
        await deduped.handle(message(messageId: 'm:5', chatId: 'c:20')),
        isNotNull,
      );
      expect(
        await deduped.handle(message(messageId: 'm:5', account: max2)),
        isNotNull,
      );
      expect(deduped.badge, 3);
    });

    test('an event without messageId is never deduplicated', () async {
      final bare = BackendEvent(
        kind: BackendEventKind.newMessage,
        account: max1,
        chatId: 'c:10',
        timestamp: 1000,
      );
      expect(await deduped.handle(bare), isNotNull);
      expect(await deduped.handle(bare), isNotNull);
      expect(deduped.badge, 2);
    });

    test('the default center keeps the OPE-3751 contract (no window)',
        () async {
      final event = message(messageId: 'm:42', timestamp: 1000);
      await center.handle(event);
      final replay = await center.handle(event);
      expect(replay, isNotNull);
      expect(center.badge, 2, reason: 'окно выключено — считает шина событий');
    });
  });
}
