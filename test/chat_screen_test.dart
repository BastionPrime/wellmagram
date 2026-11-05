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
    return const SendResult(messageId: 'sent', timestamp: 1);
  }
  @override
  Future<void> markRead(String chatId) async { reads++; }
  @override
  Future<void> setTyping(String chatId, bool typing) async {}
  @override
  Future<void> editText(String chatId, String messageId, String newText) async {}
  @override
  Future<void> deleteMessages(String chatId, List<String> messageIds) async {}
  @override
  Future<void> setReaction(String chatId, String messageId, String reaction) async {}
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

void main() {
  for (final network in [Network.max, Network.telegram]) {
    testWidgets('chat sends and reads through $network backend', (tester) async {
      final account = AccountKey(network: network, id: 1);
      final backend = FakeBackend(account, Capabilities.forNetwork(network));
      final chat = UnifiedChat(account: account, id: 'chat', title: 'Conversation', isGroup: false, lastEventTime: 0);
      await tester.pumpWidget(MaterialApp(home: ChatScreen(backend: backend, chat: chat)));
      await tester.pumpAndSettle();
      expect(backend.reads, 1);
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(backend.sends, 1);
      backend.controller.add(BackendEvent.message(account: account, chatId: 'chat', messageId: '1', senderId: 'friend', text: 'Reply', timestamp: 2));
      await tester.pump();
      expect(find.text('Reply'), findsOneWidget);
      await backend.dispose();
    });
  }
}
