import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/app/chat_list_source.dart';
import 'package:wellmagram/core/backends/capabilities.dart';
import 'package:wellmagram/core/models/unified/unified_chat.dart';
import 'package:wellmagram/ui/screens/chat_list_screen.dart';

class FixtureAggregator implements ChatListSource {
  FixtureAggregator(this.chats);
  final List<UnifiedChat> chats;
  final _controller = StreamController<List<UnifiedChat>>();
  @override
  Stream<List<UnifiedChat>> get chatListStream => _controller.stream;
  @override
  List<UnifiedChat> snapshot() => chats;
}

UnifiedChat chat(String id, String title, int time, {int unread = 0}) => UnifiedChat(
      account: const AccountKey(network: Network.max, id: 7),
      id: id,
      title: title,
      isGroup: false,
      lastEventTime: time,
      unreadCount: unread,
      lastMessagePreview: 'preview $title',
    );

void main() {
  testWidgets('renders the aggregator snapshot and keeps its ordering', (tester) async {
    final source = FixtureAggregator([chat('new', 'Newest', 20, unread: 2), chat('old', 'Older', 10)]);
    await tester.pumpWidget(MaterialApp(home: ChatListScreen(aggregator: source)));
    expect(find.text('Newest'), findsOneWidget);
    expect(find.text('Older'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Newest')).dy, lessThan(tester.getTopLeft(find.text('Older')).dy));
    expect(find.text('2'), findsOneWidget);
    expect(find.text('MAX'), findsNWidgets(2));
  });

  testWidgets('only exposes actions enabled by account capabilities', (tester) async {
    var readCalls = 0;
    var muteCalls = 0;
    final source = FixtureAggregator([chat('one', 'One', 1)]);
    await tester.pumpWidget(MaterialApp(home: ChatListScreen(
      aggregator: source,
      capabilities: {'max:7': const Capabilities(
        sendText: true, sendMedia: false, editText: false, deleteMessages: false,
        setReaction: false, markRead: true, setTyping: false, downloadMedia: false,
        calls: false, pushRegistration: false, ghostMode: false,
        setChatMuted: false, archiveChat: false,
      )},
      onMarkRead: (_) async { readCalls++; },
      onMute: (_) async { muteCalls++; },
      onArchive: (_) async {},
    )));
    await tester.drag(find.text('One'), const Offset(300, 0));
    await tester.pump();
    expect(find.byTooltip('Прочитать'), findsOneWidget);
    expect(find.byTooltip('Без звука'), findsNothing);
    expect(find.byTooltip('В архив'), findsNothing);
    await tester.tap(find.byTooltip('Прочитать'));
    await tester.pump();
    expect(readCalls, 1);
    expect(muteCalls, 0);
  });

  testWidgets('exposes mute and archive only when capabilities allow', (tester) async {
    var muteCalls = 0;
    var archiveCalls = 0;
    final source = FixtureAggregator([chat('one', 'One', 1)]);
    await tester.pumpWidget(MaterialApp(home: ChatListScreen(
      aggregator: source,
      capabilities: {'max:7': const Capabilities(
        sendText: false, sendMedia: false, editText: false, deleteMessages: false,
        setReaction: false, markRead: false, setTyping: false, downloadMedia: false,
        calls: false, pushRegistration: false, ghostMode: false,
        setChatMuted: true, archiveChat: true,
      )},
      onMarkRead: (_) async {},
      onMute: (_) async { muteCalls++; },
      onArchive: (_) async { archiveCalls++; },
    )));
    await tester.drag(find.text('One'), const Offset(300, 0));
    await tester.pump();
    expect(find.byTooltip('Прочитать'), findsNothing);
    expect(find.byTooltip('Без звука'), findsOneWidget);
    expect(find.byTooltip('В архив'), findsOneWidget);
    await tester.tap(find.byTooltip('Без звука'));
    await tester.pump();
    expect(muteCalls, 1);
    await tester.tap(find.byTooltip('В архив'));
    await tester.pump();
    expect(archiveCalls, 1);
  });

  testWidgets('shows empty state while remaining refreshable', (tester) async {
    await tester.pumpWidget(MaterialApp(home: ChatListScreen(aggregator: FixtureAggregator([]))));
    expect(find.text('Нет чатов'), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });
}
