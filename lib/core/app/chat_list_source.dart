import 'dart:convert';

import '../models/unified/unified_chat.dart';

/// Contract consumed by ChatListScreen (T-3.2).
///
/// Satisfied in production by ChatListAggregator (T-3.1).
abstract interface class ChatListSource {
  Stream<List<UnifiedChat>> get chatListStream;
  List<UnifiedChat> snapshot();
}

/// Computes the persistent storage key for a chat: `<network>:<id>/<chatId>`.
String chatListKey(UnifiedChat chat) =>
    '${chat.account.network.storageName}:${chat.account.id}/${chat.id}';

/// Durable store for pinned and muted chat keys across app restarts.
abstract interface class ChatListPinStore {
  Set<String> pinnedChatKeys();
  Set<String> mutedChatKeys();
  Future<void> setPinned(String key, {required bool pinned});
  Future<void> setMuted(String key, {required bool muted});
}

/// In-memory pin/mute store for widget tests and previews.
class InMemoryChatListPinStore implements ChatListPinStore {
  final Set<String> _pinned;
  final Set<String> _muted;

  InMemoryChatListPinStore({
    Iterable<String>? pinnedChatKeys,
    Iterable<String>? mutedChatKeys,
  })  : _pinned = Set<String>.of(pinnedChatKeys ?? const []),
        _muted = Set<String>.of(mutedChatKeys ?? const []);

  @override
  Set<String> pinnedChatKeys() => Set.unmodifiable(_pinned);

  @override
  Set<String> mutedChatKeys() => Set.unmodifiable(_muted);

  @override
  Future<void> setPinned(String key, {required bool pinned}) async {
    if (pinned) {
      _pinned.add(key);
    } else {
      _pinned.remove(key);
    }
  }

  @override
  Future<void> setMuted(String key, {required bool muted}) async {
    if (muted) {
      _muted.add(key);
    } else {
      _muted.remove(key);
    }
  }
}

/// Persistent store reading and writing JSON string sets via key-value storage.
class PrefsChatListPinStore implements ChatListPinStore {
  static const prefsKeyPinned = 'chat_list_pinned_keys_v1';
  static const prefsKeyMuted = 'chat_list_muted_keys_v1';

  final Future<String?> Function(String key) _readRaw;
  final Future<void> Function(String key, String value) _writeRaw;

  Set<String> _pinned = {};
  Set<String> _muted = {};

  PrefsChatListPinStore({
    required Future<String?> Function(String key) readRaw,
    required Future<void> Function(String key, String value) writeRaw,
  })  : _readRaw = readRaw,
        _writeRaw = writeRaw;

  @override
  Set<String> pinnedChatKeys() => Set.unmodifiable(_pinned);

  @override
  Set<String> mutedChatKeys() => Set.unmodifiable(_muted);

  Future<void> load() async {
    _pinned = _decode(await _readRaw(prefsKeyPinned));
    _muted = _decode(await _readRaw(prefsKeyMuted));
  }

  @override
  Future<void> setPinned(String key, {required bool pinned}) => _mutate(
        key: key,
        enabled: pinned,
        current: _pinned,
        storageKey: prefsKeyPinned,
        onUpdate: (s) => _pinned = s,
      );

  @override
  Future<void> setMuted(String key, {required bool muted}) => _mutate(
        key: key,
        enabled: muted,
        current: _muted,
        storageKey: prefsKeyMuted,
        onUpdate: (s) => _muted = s,
      );

  Future<void> _mutate({
    required String key,
    required bool enabled,
    required Set<String> current,
    required String storageKey,
    required void Function(Set<String>) onUpdate,
  }) async {
    final next = Set<String>.of(current);
    final changed = enabled ? next.add(key) : next.remove(key);
    if (!changed) return;
    onUpdate(next);
    final list = next.toList()..sort();
    await _writeRaw(storageKey, jsonEncode(list));
  }

  static Set<String> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toSet();
      }
    } on Object catch (_) {}
    return {};
  }
}
