import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/account_profile.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/app/chat_list_aggregator.dart';
import 'package:wellmagram/core/app/chat_list_source.dart';
import 'package:wellmagram/core/backends/capabilities.dart';
import 'package:wellmagram/core/backends/messenger_backend.dart';
import 'package:wellmagram/core/models/unified/backend_event.dart';
import 'package:wellmagram/core/models/unified/unified_chat.dart';
import 'package:wellmagram/ui/screens/chat_list_screen.dart';

const maxAccount = AccountKey(network: Network.max, id: 7);

UnifiedChat chat(String id, String title, int time, {int unread = 0}) =>
    UnifiedChat(
      account: maxAccount,
      id: id,
      title: title,
      isGroup: false,
      lastEventTime: time,
      unreadCount: unread,
      lastMessagePreview: 'preview $title',
    );

class _CountingPinStore extends InMemoryChatListPinStore {
  int pinWrites = 0;
  int muteWrites = 0;
  @override
  Future<void> setPinned(String key, {required bool pinned}) async {
    pinWrites++;
    await super.setPinned(key, pinned: pinned);
  }

  @override
  Future<void> setMuted(String key, {required bool muted}) async {
    muteWrites++;
    await super.setMuted(key, muted: muted);
  }
}

Capabilities testCaps({
  bool markRead = false,
  bool setChatMuted = false,
  bool archiveChat = false,
}) =>
    Capabilities(
      sendText: false,
      sendMedia: false,
      editText: false,
      deleteMessages: false,
      setReaction: false,
      markRead: markRead,
      setTyping: false,
      downloadMedia: false,
      calls: false,
      pushRegistration: false,
      ghostMode: false,
      setChatMuted: setChatMuted,
      archiveChat: archiveChat,
    );

Widget host({
  required ChatListSource source,
  ChatListPinStore? pinStore,
  Capabilities? accountCaps,
  Map<String, AccountProfile> accounts = const {},
  Future<void> Function(UnifiedChat)? onMarkRead,
  Future<void> Function(UnifiedChat)? onMute,
  Future<void> Function(UnifiedChat)? onArchive,
  Future<void> Function(UnifiedChat)? onPin,
}) =>
    MaterialApp(
      home: ChatListScreen(
        // Keyed by source identity so pumping a new source builds a fresh
        // screen that reads its initialData snapshot (StreamBuilder only
        // applies initialData in initState, not on stream swap).
        key: ValueKey<Object?>(source),
        aggregator: source,
        pinStore: pinStore ?? InMemoryChatListPinStore(),
        accounts: accounts,
        capabilities: {'max:7': accountCaps ?? testCaps(markRead: true)},
        onMarkRead: onMarkRead,
        onMute: onMute,
        onArchive: onArchive,
        onPin: onPin,
      ),
    );

void main() {
  testWidgets('renders aggregator snapshot, badges, and preserves sorting',
      (tester) async {
    final backend = _MockBackend(maxAccount);
    final aggregator = ChatListAggregator([backend])..start();
    addTearDown(aggregator.dispose);
    addTearDown(backend.dispose);

    aggregator.addChat(chat('old', 'Older', 10));
    aggregator.addChat(chat('new', 'Newest', 20, unread: 2));
    await tester.pumpWidget(host(
      source: aggregator,
      accounts: const {
        'max:7': AccountProfile(
          key: maxAccount,
          displayName: 'Work',
          phone: '',
          updatedAt: 1,
        ),
      },
    ));

    expect(find.text('Newest'), findsOneWidget);
    expect(find.text('Older'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Newest')).dy,
        lessThan(tester.getTopLeft(find.text('Older')).dy));
    expect(find.text('2'), findsOneWidget);
    expect(find.text('MAX'), findsNWidgets(2));
    expect(find.text('W'), findsNWidgets(2));
  });

  testWidgets('aggregator stream updates reorder the UI list',
      (tester) async {
    final backend = _MockBackend(maxAccount);
    final aggregator = ChatListAggregator([backend])..start();
    addTearDown(aggregator.dispose);
    addTearDown(backend.dispose);

    aggregator.addChat(chat('early', 'Early', 1000));
    aggregator.addChat(chat('late', 'Late', 2000));
    await tester.pumpWidget(host(source: aggregator));
    expect(tester.getTopLeft(find.text('Late')).dy,
        lessThan(tester.getTopLeft(find.text('Early')).dy));

    final update = aggregator.chatListStream.first;
    backend.emit(BackendEvent.message(
      account: maxAccount,
      chatId: 'early',
      messageId: 'm:1',
      text: 'bump',
      timestamp: 3000,
    ));
    expect((await update).first.id, 'early');
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('Early')).dy,
        lessThan(tester.getTopLeft(find.text('Late')).dy));
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('full swipe executes mark-read, mute, and archive actions',
      (tester) async {
    var readCalls = 0;
    var muteCalls = 0;
    var archiveCalls = 0;
    final pinStore = _CountingPinStore();

    await tester.pumpWidget(host(
      source: _FixtureSource([chat('one', 'One', 1)]),
      pinStore: pinStore,
      accountCaps: testCaps(markRead: true, setChatMuted: true),
      onMarkRead: (_) async => readCalls++,
      onMute: (_) async => muteCalls++,
    ));
    await tester.fling(find.text('One'), const Offset(500, 0), 1000);
    await tester.pumpAndSettle();
    expect(readCalls, 1);

    await tester.fling(find.text('One'), const Offset(-500, 0), 1000);
    await tester.pumpAndSettle();
    expect(muteCalls, 1);
    expect(pinStore.muteWrites, 1);
    expect(find.byIcon(Icons.volume_off), findsOneWidget);

    await tester.pumpWidget(host(
      source: _FixtureSource([chat('two', 'Two', 1)]),
      accountCaps: testCaps(archiveChat: true),
      onArchive: (_) async => archiveCalls++,
    ));
    await tester.fling(find.text('Two'), const Offset(-500, 0), 1000);
    await tester.pumpAndSettle();
    expect(archiveCalls, 1);
  });

  testWidgets('revealed swipe action buttons are tappable and capability-gated',
      (tester) async {
    var readCalls = 0;
    var archiveCalls = 0;
    await tester.pumpWidget(host(
      source: _FixtureSource([chat('one', 'One', 1)]),
      accountCaps: testCaps(markRead: true),
      onMarkRead: (_) async => readCalls++,
      onArchive: (_) async => archiveCalls++,
    ));

    await tester.drag(find.text('One'), const Offset(200, 0));
    await tester.pump();
    expect(find.byTooltip('Прочитать'), findsOneWidget);
    await tester.tap(find.byTooltip('Прочитать'));
    await tester.pumpAndSettle();
    expect(readCalls, 1);

    await tester.drag(find.text('One'), const Offset(-200, 0));
    await tester.pump();
    expect(find.byTooltip('В архив'), findsNothing);
    expect(find.byTooltip('Без звука'), findsNothing);
    expect(archiveCalls, 0);
  });

  testWidgets('unsupported swipe runs nothing and keeps the row',
      (tester) async {
    var archiveCalls = 0;
    await tester.pumpWidget(host(
      source: _FixtureSource([chat('one', 'One', 1)]),
      accountCaps: testCaps(),
      onArchive: (_) async => archiveCalls++,
    ));

    await tester.fling(find.text('One'), const Offset(-500, 0), 1000);
    await tester.pumpAndSettle();
    expect(archiveCalls, 0);
    expect(find.text('One'), findsOneWidget);
  });

  testWidgets('pin swipe and long press persist pin and preserve order',
      (tester) async {
    final backend = _MockBackend(maxAccount);
    final aggregator = ChatListAggregator([backend])..start();
    addTearDown(aggregator.dispose);
    addTearDown(backend.dispose);
    aggregator.addChat(chat('a', 'Alpha', 10));
    aggregator.addChat(chat('b', 'Beta', 20));
    aggregator.addChat(chat('c', 'Gamma', 30));

    final pinStore = _CountingPinStore();
    await tester.pumpWidget(host(source: aggregator, pinStore: pinStore));
    expect(find.text('Закреплённые'), findsNothing);

    await tester.longPress(find.text('Alpha'));
    await tester.pumpAndSettle();

    expect(find.text('Закреплённые'), findsOneWidget);
    expect(find.text('Прочие'), findsOneWidget);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(pinStore.pinWrites, 1);
    expect(pinStore.pinnedChatKeys(), {'max:7/a'});
    expect(tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('Gamma')).dy));
    expect(tester.getTopLeft(find.text('Gamma')).dy,
        lessThan(tester.getTopLeft(find.text('Beta')).dy));

    await tester.drag(find.text('Alpha'), const Offset(200, 0));
    await tester.pump();
    await tester.tap(find.byTooltip('Открепить'));
    await tester.pumpAndSettle();
    expect(find.text('Закреплённые'), findsNothing);
    expect(pinStore.pinnedChatKeys(), isEmpty);
  });

  testWidgets('shows empty state while remaining refreshable', (tester) async {
    await tester.pumpWidget(host(source: _FixtureSource([])));
    expect(find.text('Нет чатов'), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });
}

class _FixtureSource implements ChatListSource {
  final List<UnifiedChat> chats;
  final _controller = StreamController<List<UnifiedChat>>.broadcast();
  _FixtureSource(this.chats);
  @override
  Stream<List<UnifiedChat>> get chatListStream => _controller.stream;
  @override
  List<UnifiedChat> snapshot() => chats;
}

class _MockBackend implements MessengerBackend {
  @override
  final AccountKey account;
  final _events = StreamController<BackendEvent>.broadcast();
  _MockBackend(this.account);

  @override
  Stream<BackendEvent> get events => _events.stream;
  void emit(BackendEvent event) => _events.add(event);
  @override
  Capabilities get capabilities => Capabilities.max;
  @override
  BackendState get state => BackendState.online;
  @override
  Stream<BackendState> get stateChanges => const Stream.empty();
  @override
  Future<List<UnifiedChat>> chats() async => const [];
  @override
  Future<List<UnifiedMessage>> history(String c, {int limit = 50}) async =>
      const [];
  @override
  Future<SendResult> sendText(String c, String t) async =>
      const SendResult(messageId: 'm:mock', timestamp: 0);
  @override
  Future<void> sendMedia(String c, String p) async {}
  @override
  Future<void> editText(String c, String m, String t) async {}
  @override
  Future<void> deleteMessages(String c, List<String> m) async {}
  @override
  Future<void> setReaction(String c, String m, String r) async {}
  @override
  Future<void> markRead(String c) async {}
  @override
  Future<void> setTyping(String c, bool t) async {}
  @override
  Future<void> downloadMedia(String m, String p) async {}
  @override
  Future<void> registerPush(String t) async {}
  @override
  Future<void> unregisterPush(String t) async {}
  @override
  Future<void> setGhostMode(bool e) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> dispose() => _events.close();
}
