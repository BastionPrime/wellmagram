import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/backends/capabilities.dart';
import 'package:wellmagram/core/backends/messenger_backend.dart';
import 'package:wellmagram/core/models/unified/backend_event.dart';
import 'package:wellmagram/core/models/unified/unified_chat.dart';
import 'package:wellmagram/ui/screens/chat_screen.dart';

class FakeBackend implements MessengerBackend {
  FakeBackend(this.account, this.capabilities);
  @override
  final AccountKey account;
  @override
  final Capabilities capabilities;
  final controller = StreamController<BackendEvent>.broadcast();
  final messages = <UnifiedMessage>[];
  int reads = 0;
  int sends = 0;
  int edits = 0;
  int deletes = 0;
  final reactions = <String>[];
  @override
  Stream<BackendEvent> get events => controller.stream;
  @override
  BackendState get state => BackendState.online;
  @override
  Stream<BackendState> get stateChanges => const Stream.empty();
  @override
  Future<List<UnifiedChat>> chats() async => [];
  @override
  Future<List<UnifiedMessage>> history(String chatId, {int limit = 50}) async => messages;
  @override
  Future<SendResult> sendText(String chatId, String text) async {
    sends++;
    return SendResult(messageId: 'sent-$sends', timestamp: sends);
  }
  @override
  Future<void> markRead(String chatId) async { reads++; }
  @override
  Future<void> setTyping(String chatId, bool typing) async {}
  @override
  Future<void> editText(String chatId, String messageId, String newText) async { edits++; }
  @override
  Future<void> deleteMessages(String chatId, List<String> messageIds) async { deletes += messageIds.length; }
  @override
  Future<void> setReaction(String chatId, String messageId, String reaction) async { reactions.add(reaction); }
  @override
  Future<void> sendMedia(String chatId, String filePath) async {}
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
  Future<void> dispose() async { await controller.close(); }
}

const _noSend = Capabilities(
  sendText: false, sendMedia: false, editText: true, deleteMessages: true,
  setReaction: true, markRead: true, setTyping: true, downloadMedia: false,
  calls: false, pushRegistration: false, ghostMode: false,
);

const _readOnly = Capabilities(
  sendText: true, sendMedia: false, editText: false, deleteMessages: false,
  setReaction: false, markRead: true, setTyping: true, downloadMedia: false,
  calls: false, pushRegistration: false, ghostMode: false,
);

Future<void> _pumpChat(WidgetTester tester, FakeBackend backend, UnifiedChat chat) async {
  await tester.pumpWidget(MaterialApp(home: ChatScreen(backend: backend, chat: chat)));
  await tester.pumpAndSettle();
}

/// Delivers a backend event and renders the resulting frame.
///
/// A broadcast stream delivers on a microtask, and `pump` flushes microtasks
/// only after its frame, so the `setState` from the listener lands in the
/// following frame: the event needs a second `pump`. Deliberately not
/// `pumpAndSettle`, which would advance past [ChatScreen.typingTtl] and clear
/// the typing indicator the test is asserting on.
Future<void> _emit(WidgetTester tester, FakeBackend backend, BackendEvent event) async {
  backend.controller.add(event);
  await tester.pump();
  await tester.pump();
}

void main() {
  for (final network in [Network.max, Network.telegram]) {
    testWidgets('chat sends and reads through $network backend', (tester) async {
      final account = AccountKey(network: network, id: 1);
      final backend = FakeBackend(account, Capabilities.forNetwork(network));
      final chat = UnifiedChat(account: account, id: 'chat', title: 'Conversation', isGroup: false, lastEventTime: 0);
      await _pumpChat(tester, backend, chat);
      expect(backend.reads, 1);
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(backend.sends, 1);
      // Own message renders optimistically from SendResult.
      expect(find.text('Hello'), findsOneWidget);
      await _emit(tester, backend, BackendEvent.message(account: account, chatId: 'chat', messageId: '1', senderId: 'friend', text: 'Reply', timestamp: 2));
      expect(find.text('Reply'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await backend.dispose();
    });

    testWidgets('typing shows and stops through $network backend', (tester) async {
      final account = AccountKey(network: network, id: 1);
      final backend = FakeBackend(account, Capabilities.forNetwork(network));
      final chat = UnifiedChat(account: account, id: 'chat', title: 'Conversation', isGroup: false, lastEventTime: 0);
      await _pumpChat(tester, backend, chat);
      expect(find.byKey(const Key('typing-indicator')), findsNothing);
      await _emit(tester, backend, BackendEvent(
        kind: BackendEventKind.typing, account: account, chatId: 'chat',
        senderId: 'friend', timestamp: 3));
      expect(find.byKey(const Key('typing-indicator')), findsOneWidget);
      await _emit(tester, backend, BackendEvent(
        kind: BackendEventKind.typing, account: account, chatId: 'chat',
        senderId: 'friend', text: 'false', timestamp: 4));
      expect(find.byKey(const Key('typing-indicator')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await backend.dispose();
    });

    testWidgets('edit/delete/react gated by capabilities ($network)', (tester) async {
      final account = AccountKey(network: network, id: 1);
      final backend = FakeBackend(account, _readOnly);
      backend.messages.add(UnifiedMessage(
        account: account, chatId: 'chat', id: 'm1',
        senderId: 'friend', text: 'Hi', timestamp: 1));
      final chat = UnifiedChat(account: account, id: 'chat', title: 'Conversation', isGroup: false, lastEventTime: 0);
      await _pumpChat(tester, backend, chat);
      expect(find.text('Hi'), findsOneWidget);
      expect(find.byTooltip('Edit'), findsNothing);
      expect(find.byTooltip('Delete'), findsNothing);
      expect(find.byTooltip('React'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await backend.dispose();
    });
  }

  testWidgets('typing indicator expires after the TTL without new events', (tester) async {
    final account = AccountKey(network: Network.max, id: 1);
    final backend = FakeBackend(account, Capabilities.forNetwork(Network.max));
    final chat = UnifiedChat(account: account, id: 'chat', title: 'Conversation', isGroup: false, lastEventTime: 0);
    await _pumpChat(tester, backend, chat);
    await _emit(tester, backend, BackendEvent(
      kind: BackendEventKind.typing, account: account, chatId: 'chat',
      senderId: 'friend', timestamp: 3));
    expect(find.byKey(const Key('typing-indicator')), findsOneWidget);
    await tester.pump(ChatScreen.typingTtl + const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const Key('typing-indicator')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await backend.dispose();
  });

  testWidgets('composer hidden when sendText is false', (tester) async {
    final account = AccountKey(network: Network.max, id: 1);
    final backend = FakeBackend(account, _noSend);
    final chat = UnifiedChat(account: account, id: 'chat', title: 'Conversation', isGroup: false, lastEventTime: 0);
    await _pumpChat(tester, backend, chat);
    expect(find.byTooltip('Send'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await backend.dispose();
  });

  testWidgets('react picker sends chosen emoji', (tester) async {
    final account = AccountKey(network: Network.max, id: 1);
    final backend = FakeBackend(account, Capabilities.max);
    backend.messages.add(UnifiedMessage(
      account: account, chatId: 'chat', id: 'm1',
      senderId: 'friend', text: 'Hi', timestamp: 1));
    final chat = UnifiedChat(account: account, id: 'chat', title: 'Conversation', isGroup: false, lastEventTime: 0);
    await _pumpChat(tester, backend, chat);
    await tester.tap(find.byTooltip('React'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('❤️'));
    await tester.pumpAndSettle();
    expect(backend.reactions, ['❤️']);
    await tester.pumpWidget(const SizedBox.shrink());
    await backend.dispose();
  });
}
