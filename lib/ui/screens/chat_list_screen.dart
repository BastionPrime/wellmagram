import 'package:flutter/material.dart';

import '../../core/accounts/account_profile.dart';
import '../../core/backends/capabilities.dart';
import '../../core/models/unified/unified_chat.dart';
import '../../core/app/chat_list_source.dart';

class ChatListScreen extends StatelessWidget {
  final ChatListSource aggregator;
  final Map<String, AccountProfile> accounts;
  final Map<String, Capabilities> capabilities;
  final Set<String> pinnedChatKeys;
  final Set<String> mutedChatKeys;
  final Future<void> Function(UnifiedChat chat)? onMarkRead;
  final Future<void> Function(UnifiedChat chat)? onMute;
  final Future<void> Function(UnifiedChat chat)? onArchive;
  final ValueChanged<UnifiedChat>? onOpenChat;

  const ChatListScreen({
    super.key,
    required this.aggregator,
    this.accounts = const {},
    this.capabilities = const {},
    this.pinnedChatKeys = const {},
    this.mutedChatKeys = const {},
    this.onMarkRead,
    this.onMute,
    this.onArchive,
    this.onOpenChat,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Чаты')),
        body: RefreshIndicator(
          onRefresh: () async {},
          child: StreamBuilder<List<UnifiedChat>>(
            stream: aggregator.chatListStream,
            initialData: aggregator.snapshot(),
            builder: (context, snapshot) {
              final chats = snapshot.data ?? const <UnifiedChat>[];
              final pinned = chats.where((chat) => _isPinned(chat)).toList();
              final others = chats.where((chat) => !_isPinned(chat)).toList();
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (pinned.isNotEmpty) ...[
                    const _SectionHeader('Закреплённые'),
                    ...pinned.map((chat) => _tile(context, chat)),
                  ],
                  if (others.isNotEmpty) ...[
                    const _SectionHeader('Прочие'),
                    ...others.map((chat) => _tile(context, chat)),
                  ],
                  if (chats.isEmpty)
                    const SizedBox(height: 240, child: Center(child: Text('Нет чатов'))),
                ],
              );
            },
          ),
        ),
      );

  String _key(UnifiedChat chat) => '${chat.account.storageId}/${chat.id}';

  bool _isPinned(UnifiedChat chat) => pinnedChatKeys.contains(_key(chat));

  Widget _tile(BuildContext context, UnifiedChat chat) {
    final account = accounts[chat.account.storageId];
    final caps = capabilities[chat.account.storageId] ??
        Capabilities.forNetwork(chat.account.network);
    final actions = <Widget>[];
    if (caps.markRead && onMarkRead != null) {
      actions.add(_action('Прочитать', Icons.mark_chat_read, onMarkRead!, chat));
    }
    if (caps.setChatMuted && onMute != null) {
      actions.add(_action('Без звука', Icons.volume_off, onMute!, chat));
    }
    if (caps.archiveChat && onArchive != null) {
      actions.add(_action('В архив', Icons.archive, onArchive!, chat));
    }
    Widget tile = ListTile(
      leading: CircleAvatar(
        backgroundImage: chat.avatarUrl == null ? null : NetworkImage(chat.avatarUrl!),
        child: chat.avatarUrl == null ? Text(_initial(chat.title)) : null,
      ),
      title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(children: [
        _NetworkBadge(chat: chat),
        const SizedBox(width: 6),
        Expanded(child: Text(chat.lastMessagePreview ?? '', maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (chat.unreadCount > 0)
          CircleAvatar(radius: 12, child: Text('${chat.unreadCount}', style: const TextStyle(fontSize: 11))),
        if (mutedChatKeys.contains(_key(chat)))
          const Icon(Icons.volume_off, size: 18),
        if (account != null) ...[
          const SizedBox(width: 8),
          CircleAvatar(radius: 14, child: Text(_initial(account.displayName), style: const TextStyle(fontSize: 11))),
        ],
      ]),
      onTap: onOpenChat == null ? null : () => onOpenChat!(chat),
    );
    if (actions.isNotEmpty) {
      tile = Dismissible(
        key: ValueKey('${chat.account.storageId}/${chat.id}'),
        background: Row(children: actions),
        secondaryBackground: Row(mainAxisAlignment: MainAxisAlignment.end, children: actions.reversed.toList()),
        confirmDismiss: (_) async => false,
        child: tile,
      );
    }
    return tile;
  }

  bool _muted(UnifiedChat chat) => false;

  String _initial(String value) => value.isEmpty ? '?' : String.fromCharCode(value.runes.first).toUpperCase();

  Widget _action(String label, IconData icon, Future<void> Function(UnifiedChat) callback, UnifiedChat chat) =>
      Builder(builder: (context) => IconButton(
            tooltip: label,
            icon: Icon(icon),
            onPressed: () => callback(chat),
          ));
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
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
        child: Text(chat.account.network.storageName.toUpperCase(), style: const TextStyle(fontSize: 9)),
      );
}
