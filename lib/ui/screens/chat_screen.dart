import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backends/messenger_backend.dart';
import '../../core/models/unified/backend_event.dart';
import '../../core/models/unified/unified_chat.dart';
import '../widgets/message_bubble.dart';

/// Unified conversation screen (OPE-2270 T-3.3).
///
/// Typing fallback: backends emit [BackendEventKind.typing] without a
/// dedicated "stopped" frame, so the screen treats an event with
/// `text == 'false'` as "stopped" AND clears a shown indicator after
/// [typingTtl] without a new typing event for the same sender.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.backend, required this.chat});

  final MessengerBackend backend;
  final UnifiedChat chat;

  @visibleForTesting
  static const typingTtl = Duration(seconds: 6);

  @visibleForTesting
  static const reactionChoices = ['👍', '❤️', '😂', '😮', '😢'];

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _composer = TextEditingController();
  StreamSubscription<BackendEvent>? _subscription;
  List<UnifiedMessage> _messages = [];
  String? _typing;
  Timer? _typingTimer;
  String? _error;
  bool _busy = false;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend != widget.backend || oldWidget.chat != widget.chat) {
      _subscription?.cancel();
      _connect();
    }
  }

  void _connect() {
    final generation = ++_generation;
    _messages = [];
    _typing = null;
    _typingTimer?.cancel();
    _typingTimer = null;
    _loading = true;
    _subscription = widget.backend.events.listen(_onEvent);
    _load(generation);
  }

  Future<void> _load(int generation) async {
    try {
      final history = await widget.backend.history(widget.chat.id);
      if (!mounted || generation != _generation) return;
      setState(() {
        // Preserve events that arrived while history was loading.
        final byId = {for (final message in history) message.id: message};
        for (final message in _messages) { byId[message.id] = message; }
        _messages = byId.values.toList()..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        _loading = false;
      });
      if (widget.backend.capabilities.markRead) await widget.backend.markRead(widget.chat.id);
    } on Object catch (error) {
      if (mounted && generation == _generation) setState(() { _error = error.toString(); _loading = false; });
    }
  }

  void _onEvent(BackendEvent event) {
    if (!mounted || event.account != widget.chat.account || event.chatId != widget.chat.id) return;
    setState(() {
      switch (event.kind) {
        case BackendEventKind.newMessage:
          if (event.messageId != null && !_messages.any((m) => m.id == event.messageId)) {
            _messages.add(UnifiedMessage(account: event.account, chatId: widget.chat.id,
              id: event.messageId!, senderId: event.senderId ?? '', text: event.text ?? '', timestamp: event.timestamp));
            _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          }
          if (widget.backend.capabilities.markRead) unawaited(widget.backend.markRead(widget.chat.id));
        case BackendEventKind.messageEdited:
          _messages = _messages.map((m) => m.id == event.messageId ? m.copyWith(text: event.text ?? m.text) : m).toList();
        case BackendEventKind.messageDeleted:
          _messages.removeWhere((m) => m.id == event.messageId);
        case BackendEventKind.typing:
          _applyTyping(event);
        default:
          break;
      }
    });
  }

  void _applyTyping(BackendEvent event) {
    if (event.text == 'false') {
      _typing = null;
      _typingTimer?.cancel();
      _typingTimer = null;
      return;
    }
    _typing = event.senderId ?? 'Typing';
    _typingTimer?.cancel();
    final shown = _typing;
    _typingTimer = Timer(ChatScreen.typingTtl, () {
      if (!mounted) return;
      // Clear only if no newer typing event replaced the indicator.
      if (_typing == shown) setState(() { _typing = null; _typingTimer = null; });
    });
  }

  Future<void> _perform(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try { await operation(); }
    on Object catch (error) { if (mounted) setState(() => _error = error.toString()); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || !widget.backend.capabilities.sendText) return;
    await _perform(() async {
      final result = await widget.backend.sendText(widget.chat.id, text);
      if (!mounted) return;
      _composer.clear();
      // Optimistic local echo from SendResult; backend echo dedupes by id.
      if (!_messages.any((m) => m.id == result.messageId)) {
        setState(() {
          _messages.add(UnifiedMessage(
            account: widget.chat.account,
            chatId: widget.chat.id,
            id: result.messageId,
            senderId: widget.chat.account.storageId,
            text: text,
            timestamp: result.timestamp,
          ));
          _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        });
      }
      if (widget.backend.capabilities.setTyping) await widget.backend.setTyping(widget.chat.id, false);
    });
  }

  Future<void> _edit(UnifiedMessage message) async {
    final controller = TextEditingController(text: message.text);
    final text = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: const Text('Edit message'), content: TextField(controller: controller),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save'))]));
    controller.dispose();
    if (text != null && text.isNotEmpty && text != message.text && widget.backend.capabilities.editText) {
      await _perform(() => widget.backend.editText(widget.chat.id, message.id, text));
    }
  }

  Future<void> _react(UnifiedMessage message) async {
    final reaction = await showDialog<String>(context: context, builder: (context) => SimpleDialog(
      title: const Text('Choose reaction'),
      children: [for (final emoji in ChatScreen.reactionChoices)
        SimpleDialogOption(onPressed: () => Navigator.pop(context, emoji), child: Text(emoji, style: const TextStyle(fontSize: 24)))]));
    if (reaction != null && widget.backend.capabilities.setReaction) {
      await _perform(() => widget.backend.setReaction(widget.chat.id, message.id, reaction));
    }
  }

  @override
  void dispose() {
    ++_generation;
    _subscription?.cancel();
    _typingTimer?.cancel();
    _composer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.chat.title)),
    body: Column(children: [
      if (_error != null) Text(_error!, key: const Key('chat-error')),
      Expanded(child: _loading ? const Center(child: CircularProgressIndicator()) : ListView.builder(
        itemCount: _messages.length,
        itemBuilder: (context, index) {
          final message = _messages[index];
          final caps = widget.backend.capabilities;
          return MessageBubble(message: message,
            onEdit: caps.editText && !_busy ? () => _edit(message) : null,
            onDelete: caps.deleteMessages && !_busy ? () => _perform(() => widget.backend.deleteMessages(widget.chat.id, [message.id])) : null,
            onReact: caps.setReaction && !_busy ? () => _react(message) : null);
        })),
      if (_typing != null) Text('$_typing is typing', key: const Key('typing-indicator')),
      if (widget.backend.capabilities.sendText) Row(children: [
        Expanded(child: TextField(controller: _composer, decoration: const InputDecoration(hintText: 'Message'),
          onChanged: (_) { if (widget.backend.capabilities.setTyping) unawaited(widget.backend.setTyping(widget.chat.id, true)); })),
        IconButton(tooltip: 'Send', onPressed: _busy ? null : _send, icon: const Icon(Icons.send)),
      ]),
    ]),
  );
}
