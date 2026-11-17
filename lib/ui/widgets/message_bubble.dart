import 'package:flutter/material.dart';

import '../../core/models/unified/unified_chat.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message, this.onEdit, this.onDelete, this.onReact});

  final UnifiedMessage message;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onReact;

  @override
  Widget build(BuildContext context) => Card(
        key: ValueKey('message-${message.id}'),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(message.senderId, style: Theme.of(context).textTheme.labelSmall),
              Text(message.text),
            ])),
            if (onReact != null) IconButton(tooltip: 'React', icon: const Icon(Icons.add_reaction_outlined), onPressed: onReact),
            if (onEdit != null) IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: onEdit),
            if (onDelete != null) IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: onDelete),
          ]),
        ),
      );
}
