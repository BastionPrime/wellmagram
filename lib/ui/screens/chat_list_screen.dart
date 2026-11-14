import 'dart:async' show unawaited;

// ignore: depend_on_referenced_packages
import 'package:flutter/material.dart';

import '../../core/accounts/account_profile.dart';
import '../../core/app/chat_list_source.dart';
import '../../core/backends/capabilities.dart';
import '../../core/models/unified/unified_chat.dart';

/// Unified chat list screen (Phase 3, T-3.2) backed by [ChatListSource] (T-3.1).
class ChatListScreen extends StatefulWidget {
  final ChatListSource aggregator;
  final ChatListPinStore pinStore;
  final Map<String, AccountProfile> accounts;
  final Map<String, Capabilities> capabilities;
  final Future<void> Function(UnifiedChat chat)? onMarkRead;
  final Future<void> Function(UnifiedChat chat)? onMute;
  final Future<void> Function(UnifiedChat chat)? onArchive;
  final Future<void> Function(UnifiedChat chat)? onPin;
  final ValueChanged<UnifiedChat>? onOpenChat;

  const ChatListScreen({
    super.key,
    required this.aggregator,
    required this.pinStore,
    this.accounts = const {},
    this.capabilities = const {},
    this.onMarkRead,
    this.onMute,
    this.onArchive,
    this.onPin,
    this.onOpenChat,
  });

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  late Set<String> _pinnedKeys;
  late Set<String> _mutedKeys;

  @override
  void initState() {
    super.initState();
    _syncFromStore();
  }

  @override
  void didUpdateWidget(covariant ChatListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pinStore != widget.pinStore) _syncFromStore();
  }

  void _syncFromStore() {
    _pinnedKeys = Set<String>.of(widget.pinStore.pinnedChatKeys());
    _mutedKeys = Set<String>.of(widget.pinStore.mutedChatKeys());
  }

  bool _isPinned(UnifiedChat chat) => _pinnedKeys.contains(chatListKey(chat));
  bool _isMuted(UnifiedChat chat) => _mutedKeys.contains(chatListKey(chat));

  Future<void> _togglePin(UnifiedChat chat) async {
    final key = chatListKey(chat);
    final next = !_pinnedKeys.contains(key);
    await widget.pinStore.setPinned(key, pinned: next);
    if (mounted) {
      setState(() => next ? _pinnedKeys.add(key) : _pinnedKeys.remove(key));
    }
    await widget.onPin?.call(chat);
  }

  Future<void> _toggleMute(UnifiedChat chat) async {
    final key = chatListKey(chat);
    final next = !_mutedKeys.contains(key);
    await widget.pinStore.setMuted(key, muted: next);
    if (mounted) {
      setState(() => next ? _mutedKeys.add(key) : _mutedKeys.remove(key));
    }
    await widget.onMute?.call(chat);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Чаты')),
        body: RefreshIndicator(
          onRefresh: () async {},
          child: StreamBuilder<List<UnifiedChat>>(
            stream: widget.aggregator.chatListStream,
            initialData: widget.aggregator.snapshot(),
            builder: (context, snapshot) {
              final chats = snapshot.data ?? const <UnifiedChat>[];
              final pinned = chats.where(_isPinned).toList(growable: false);
              final others =
                  chats.where((c) => !_isPinned(c)).toList(growable: false);
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (pinned.isNotEmpty) ...[
                    const _SectionHeader('Закреплённые'),
                    ...pinned.map((c) => _tile(context, c)),
                  ],
                  if (others.isNotEmpty) ...[
                    const _SectionHeader('Прочие'),
                    ...others.map((c) => _tile(context, c)),
                  ],
                  if (chats.isEmpty)
                    const SizedBox(
                      height: 240,
                      child: Center(child: Text('Нет чатов')),
                    ),
                ],
              );
            },
          ),
        ),
      );

  Widget _tile(BuildContext context, UnifiedChat chat) {
    final account = widget.accounts[chat.account.storageId];
    final caps = widget.capabilities[chat.account.storageId] ??
        Capabilities.forNetwork(chat.account.network);
    final muted = _isMuted(chat);
    final pinned = _isPinned(chat);

    final tile = ListTile(
      leading: CircleAvatar(
        backgroundImage:
            chat.avatarUrl == null ? null : NetworkImage(chat.avatarUrl!),
        child: chat.avatarUrl == null ? Text(_initial(chat.title)) : null,
      ),
      title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(children: [
        _NetworkBadge(chat: chat),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            chat.lastMessagePreview ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (chat.unreadCount > 0)
          CircleAvatar(
            radius: 12,
            child: Text('${chat.unreadCount}', style: const TextStyle(fontSize: 11)),
          ),
        if (pinned) const Icon(Icons.push_pin, size: 16),
        if (muted) const Icon(Icons.volume_off, size: 18),
        if (account != null) ...[
          const SizedBox(width: 8),
          CircleAvatar(
            radius: 14,
            child: Text(
              _initial(account.displayName),
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ]),
      onTap: widget.onOpenChat == null ? null : () => widget.onOpenChat!(chat),
      onLongPress: () => unawaited(_togglePin(chat)),
    );

    final swipeLeft = <_SwipeAction>[
      if (caps.markRead && widget.onMarkRead != null)
        _SwipeAction(
          tooltip: 'Прочитать',
          icon: Icons.mark_chat_read,
          run: () async => widget.onMarkRead!(chat),
        ),
      if (widget.onPin != null || widget.onMarkRead == null)
        _SwipeAction(
          tooltip: pinned ? 'Открепить' : 'Закрепить',
          icon: pinned ? Icons.push_pin_outlined : Icons.push_pin,
          run: () async => _togglePin(chat),
        ),
    ];

    final swipeRight = <_SwipeAction>[
      if (caps.setChatMuted &&
          (widget.onMute != null || widget.onArchive == null))
        _SwipeAction(
          tooltip: muted ? 'Включить звук' : 'Без звука',
          icon: muted ? Icons.volume_up : Icons.volume_off,
          run: () async => _toggleMute(chat),
        ),
      if (caps.archiveChat && widget.onArchive != null)
        _SwipeAction(
          tooltip: 'В архив',
          icon: Icons.archive,
          run: () async => widget.onArchive!(chat),
        ),
    ];

    if (swipeLeft.isEmpty && swipeRight.isEmpty) return tile;

    final direction = swipeLeft.isNotEmpty && swipeRight.isNotEmpty
        ? DismissDirection.horizontal
        : swipeLeft.isNotEmpty
            ? DismissDirection.startToEnd
            : DismissDirection.endToStart;

    return Dismissible(
      key: ValueKey(chatListKey(chat)),
      direction: direction,
      background: swipeLeft.isEmpty
          ? const ColoredBox(color: Colors.transparent)
          : Row(children: [for (final a in swipeLeft) _actionButton(a)]),
      secondaryBackground: swipeRight.isEmpty
          ? null
          : Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [for (final a in swipeRight.reversed) _actionButton(a)],
            ),
      confirmDismiss: (swipeDir) async {
        final actions =
            swipeDir == DismissDirection.startToEnd ? swipeLeft : swipeRight;
        if (actions.isNotEmpty) await actions.first.run();
        return false;
      },
      child: tile,
    );
  }

  String _initial(String value) => value.isEmpty
      ? '?'
      : String.fromCharCode(value.runes.first).toUpperCase();

  Widget _actionButton(_SwipeAction a) => IconButton(
        tooltip: a.tooltip,
        icon: Icon(a.icon),
        onPressed: () => unawaited(a.run()),
      );
}

class _SwipeAction {
  final String tooltip;
  final IconData icon;
  final Future<void> Function() run;
  const _SwipeAction({required this.tooltip, required this.icon, required this.run});
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _NetworkBadge extends StatelessWidget {
  final UnifiedChat chat;
  const _NetworkBadge({required this.chat});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          chat.account.network.storageName.toUpperCase(),
          style: const TextStyle(fontSize: 9),
        ),
      );
}
