import 'package:test/test.dart';
import 'package:wellmagram/core/accounts/account_key.dart';
import 'package:wellmagram/core/accounts/network.dart';
import 'package:wellmagram/core/app/chat_list_source.dart';
import 'package:wellmagram/core/models/unified/unified_chat.dart';

void main() {
  const maxAccount = AccountKey(network: Network.max, id: 7);
  const tgAccount = AccountKey(network: Network.telegram, id: 42);

  UnifiedChat makeChat(AccountKey account, String id) => UnifiedChat(
        account: account,
        id: id,
        title: 'Chat',
        isGroup: false,
        lastEventTime: 1000,
      );

  test('chatListKey produces stable storage keys', () {
    expect(chatListKey(makeChat(maxAccount, 'c100')), 'max:7/c100');
    expect(chatListKey(makeChat(tgAccount, 't200')), 'tg:42/t200');
  });

  test('InMemoryChatListPinStore toggles pinned and muted keys', () async {
    final store = InMemoryChatListPinStore();
    await store.setPinned('max:7/c1', pinned: true);
    expect(store.pinnedChatKeys(), {'max:7/c1'});
    await store.setPinned('max:7/c1', pinned: false);
    expect(store.pinnedChatKeys(), isEmpty);

    await store.setMuted('max:7/c1', muted: true);
    expect(store.mutedChatKeys(), {'max:7/c1'});
    await store.setMuted('max:7/c1', muted: false);
    expect(store.mutedChatKeys(), isEmpty);
  });

  test('PrefsChatListPinStore persists JSON across restarts and handles bad data',
      () async {
    final storage = <String, String>{
      PrefsChatListPinStore.prefsKeyPinned: '["max:7/c1","tg:42/t2"]',
      PrefsChatListPinStore.prefsKeyMuted: '["max:7/c1"]',
    };
    final store = PrefsChatListPinStore(
      readRaw: (k) async => storage[k],
      writeRaw: (k, v) async => storage[k] = v,
    );
    await store.load();
    expect(store.pinnedChatKeys(), {'max:7/c1', 'tg:42/t2'});
    expect(store.mutedChatKeys(), {'max:7/c1'});

    await store.setPinned('max:7/c3', pinned: true);
    await store.setMuted('max:7/c1', muted: false);

    final restarted = PrefsChatListPinStore(
      readRaw: (k) async => storage[k],
      writeRaw: (k, v) async => storage[k] = v,
    );
    await restarted.load();
    expect(restarted.pinnedChatKeys(), {'max:7/c1', 'max:7/c3', 'tg:42/t2'});
    expect(restarted.mutedChatKeys(), isEmpty);

    storage[PrefsChatListPinStore.prefsKeyPinned] = '{bad json';
    storage[PrefsChatListPinStore.prefsKeyMuted] = '42';
    await restarted.load();
    expect(restarted.pinnedChatKeys(), isEmpty);
    expect(restarted.mutedChatKeys(), isEmpty);
  });
}
