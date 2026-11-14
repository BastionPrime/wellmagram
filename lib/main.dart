import 'dart:async' show unawaited;

// The SDK package is provided via dependency_overrides (workspace-internal
// resolution, see pubspec.yaml); an explicit dependency entry is impossible,
// so this import's lint is suppressed.
// ignore: depend_on_referenced_packages
import 'package:flutter/material.dart';

import 'core/accounts/account_profile.dart';
import 'core/app/chat_list_aggregator.dart';
import 'core/app/chat_list_source.dart';
import 'core/backends/capabilities.dart';
import 'core/models/unified/unified_chat.dart';
import 'ui/screens/chat_list_screen.dart';

// Unified wellmagram app entry (Phase 3). Hosts the unified chat list UI
// backed by ChatListAggregator (Phase 3 T-3.1/T-3.2).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WellmagramApp());
}

/// Main wellmagram application widget hosting the unified chat list UI (Phase 3).
class WellmagramApp extends StatefulWidget {
  final String? initialRoute;
  final ChatListSource? chatListSource;
  final ChatListPinStore? pinStore;
  final Map<String, AccountProfile> accounts;
  final Map<String, Capabilities> capabilities;
  final Future<void> Function(UnifiedChat chat)? onMarkRead;
  final Future<void> Function(UnifiedChat chat)? onMute;
  final Future<void> Function(UnifiedChat chat)? onArchive;
  final Future<void> Function(UnifiedChat chat)? onPin;
  final ValueChanged<UnifiedChat>? onOpenChat;

  const WellmagramApp({
    super.key,
    this.initialRoute,
    this.chatListSource,
    this.pinStore,
    this.accounts = const {},
    this.capabilities = const {},
    this.onMarkRead,
    this.onMute,
    this.onArchive,
    this.onPin,
    this.onOpenChat,
  });

  @override
  State<WellmagramApp> createState() => _WellmagramAppState();
}

class _WellmagramAppState extends State<WellmagramApp> {
  late ChatListSource _source;
  late ChatListPinStore _pinStore;
  ChatListAggregator? _ownedAggregator;

  @override
  void initState() {
    super.initState();
    _initSource();
  }

  void _initSource() {
    if (widget.chatListSource != null) {
      _source = widget.chatListSource!;
    } else {
      _ownedAggregator = ChatListAggregator(const [])..start();
      _source = _ownedAggregator!;
    }
    _pinStore = widget.pinStore ?? InMemoryChatListPinStore();
  }

  @override
  void didUpdateWidget(covariant WellmagramApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatListSource != widget.chatListSource ||
        oldWidget.pinStore != widget.pinStore) {
      _ownedAggregator?.dispose();
      _ownedAggregator = null;
      _initSource();
    }
  }

  @override
  void dispose() {
    _ownedAggregator?.dispose();
    super.dispose();
  }

  Widget _buildChatListScreen(BuildContext context) => ChatListScreen(
        aggregator: _source,
        pinStore: _pinStore,
        accounts: widget.accounts,
        capabilities: widget.capabilities,
        onMarkRead: widget.onMarkRead,
        onMute: widget.onMute,
        onArchive: widget.onArchive,
        onPin: widget.onPin,
        onOpenChat: widget.onOpenChat,
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'wellmagram',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2f6f4f)),
      ),
      initialRoute: widget.initialRoute,
      routes: {
        '/': _buildChatListScreen,
        '/chats': _buildChatListScreen,
        '/status': (context) => const StatusScreen(),
      },
    );
  }
}

class StatusScreen extends StatelessWidget {
  const StatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('wellmagram')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Ядро готово: аккаунты · сессии · TDLib-мост'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => unawaited(Navigator.of(context).pushNamed('/chats')),
              child: const Text('К списку чатов'),
            ),
          ],
        ),
      ),
    );
  }
}
