/// Read-only UI contract implemented by the Phase 3 chat aggregator.
library;

import 'dart:async';

import '../models/unified/unified_chat.dart';

abstract interface class ChatListSource {
  Stream<List<UnifiedChat>> get chatListStream;
  List<UnifiedChat> snapshot();
}
