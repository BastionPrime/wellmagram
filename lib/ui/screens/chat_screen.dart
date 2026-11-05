import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/backends/messenger_backend.dart';
import '../../core/models/unified/backend_event.dart';
import '../../core/models/unified/unified_chat.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.backend, required this.chat});

  final MessengerBackend backend;
  final UnifiedChat chat;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _composer = TextEditingController();
  StreamSubscription<BackendEvent>? _subscription;
  List<UnifiedMessage> _messages = [];
  String? _typing;
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
    } catch (error) {
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
          _typing = event.text == 'false' ? null : (event.senderId ?? 'Typing');
        default:
          break;
      }
    });
  }

  Future<void> _perform(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try { await operation(); }
    catch (error) { if (mounted) setState(() => _error = error.toString()); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || !widget.backend.capabilities.sendText) return;
    await _perform(() async {
      await widget.backend.sendText(widget.chat.id, text);
      if (mounted) _composer.clear();
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

  @override
  void dispose() {
    ++_generation;
    _subscription?.cancel();
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
            onReact: caps.setReaction && !_busy ? () => _perform(() => widget.backend.setReaction(widget.chat.id, message.id, '👍')) : null);
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
