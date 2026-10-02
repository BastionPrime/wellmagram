# Testing map

308 unit tests across 29 `test/*_test.dart` files keep the pure-Dart core
(`lib/core/**`) green. This page is the map: which file tests which domain,
and how to run them. Nothing here requires a device, an emulator, or a live
network — every backend is driven through Dart seams (fakes and mocks).

## How to run

Prerequisites: Flutter SDK 3.38+ (Dart 3.10) in PATH; `flutter pub get`
resolves `pubspec.yaml` (the SDK provides the `flutter` path override).

```bash
flutter pub get          # resolve dependencies
flutter test             # full run: all 29 files, 308 tests (no device needed)
dart test                # same suite, plain Dart — core modules need no Flutter SDK packages

# single file (fastest loop while working on one module)
dart test test/account_key_test.dart

# single file with the Flutter runner (same result, flutter tooling)
flutter test test/td_messages_test.dart

# single test by name inside a file
dart test test/td_messages_test.dart --name "sendText sends the schema-shaped sendMessage request"  # substring match — group prefix not needed

# filter by name across the suite (substring match, case-sensitive)
dart test --name "ghost"
```

`dart test` and `flutter test` are interchangeable for this repo: no test
imports `flutter_test` or touches a plugin — storage and secure-key paths go
through `SecureStorageLike` / `AccountsStore.usePrefsLoader` seams with
in-memory fakes (see "Test infrastructure" below).

### Related tooling

- `tools/td_schema_check.py` — machine-checks every TDLib json field name
  (production literals, fixtures, and `json['key']` reads) against the
  official `td_api.tl`. Run it whenever you touch Telegram API mappings;
  exit code 0 = all names verified.
- `tools/coverage.sh` (on branch `filler-coverage-gate`, not merged yet) —
  `flutter test --coverage` + lcov summary per `lib/core/*` directory;
  once that branch merges, the command is `tools/coverage.sh` and
  `tools/coverage.sh --min-line 80` as a gate.

## Test map

Domains: **accounts** (keys, profiles, registry, credentials, codec,
session policy), **backends** (MAX backend + Telegram TDLib bridge, split
by feature), **storage** (per-account databases, media cache, spoof
profiles), **notifications** (notification center). Files that span several
domains are listed under each, with the primary domain first.

### accounts

| Test file | What it covers | Key scenarios |
| --- | --- | --- |
| `account_key_test.dart` | `AccountKey`, `Network` | storageId naming, equality/hash, ordering, `tryParse` round-trip and malformed rejection |
| `account_registry_test.dart` | `AccountRegistry`, events | add/remove/update persists and emits events, active-account policy, store round-trip, sorted unmodifiable profile list |
| `accounts_codec_test.dart` | snapshot JSON codec | round-trip, invalid/empty JSON → null, newer-version snapshot rejected, unknown networks dropped, no secret fields in JSON |
| `credential_store_test.dart` | `CredentialStore` | `cred:<net>:<id>` namespace, legacy `auth_token_<id>` migration, token lifecycle, per-network isolation, account-wide cleanup, plugin seam |
| `session_manager_test.dart` | `SessionManager` (app layer) | switch vs parallel session modes, one backend per account, ghost mode application, pause/resume, removeAccount teardown, TG rejection in this layer |
| `spoof_bridge_test.dart` | `SpoofBridge` (accounts↔storage seam) | profile → upstream `getSpoofedSessionData` shape, disabled/missing → null, remove delegates to store |
| `connection_service_controller_test.dart` | `ConnectionServiceController` (app layer) | reconnect backoff doubling and cap, reconnect signals while paused, pause/resume of live sessions, connected-account count to the platform channel, unknown signals ignored |

### backends — MAX

| Test file | What it covers | Key scenarios |
| --- | --- | --- |
| `max_backend_test.dart` | `MaxBackend` | connectAndLogin with credential, unified chats/history/sendText mapping, chatId parsing, markRead/typing/push, ghost mode ↔ invisible, state streams, pause/resume |
| `max_mappers_test.dart` | `MaxMappers`, `SessionSpec` | spec building, server payloads → unified chat/message/event mapping |
| `antiban_rate_limiter_test.dart` | `AntibanRateLimiter` | burst behaviour, status stream for UI, integration with the MaxApi seam |
| `backend_event_test.dart` | `BackendEvent` (unified model) | constructor fields, equality across all fields, no transport-source field, all notification-relevant kinds present |
| `capabilities_test.dart` | `Capabilities` | MAX fully enabled, Telegram text-first baseline, per-network presets, distinct sets |
| `messenger_backend_test.dart` | `MessengerBackend` contract | the interface itself: a minimal implementation satisfies it, pause/resume state machine, sendText/history shapes |

### backends — Telegram (TDLib)

All `td_*` files drive `TdBridge` through `MockTdClient` (in-memory
`TdClientLike`), except `td_ffi_client_test.dart` which fakes the FFI
injection points — no `libtdjson` is ever loaded in unit tests.

| Test file | What it covers | Key scenarios |
| --- | --- | --- |
| `td_bridge_test.dart` | `TdBridge`, `TdResponse` | request/response correlation by `@extra`, timeouts, update feed, reconnect policy, content-free logging, lifecycle |
| `td_auth_flow_test.dart` | `TdAuthFlow`, `TdDatabaseKeyStore` | phone → code → ready, 2FA password path, wrong code, step gating, per-account DB keys in `cred:telegram` namespace |
| `td_sessions_test.dart` | `TdSessions` | per-account `tg/<id>` directories, idempotent start, ghost profile persistence + restore order, MAX keys rejected, stop/dispose |
| `td_chat_store_test.dart` | `TdChatStore`, TG→Unified mappers | ingest + updates, loadChats/history requests, mapping into `UnifiedChat` |
| `td_messages_test.dart` | `TdMessages` | id parsers, sendText/editText/deleteMessages/addReaction wire shapes, TDLib error propagation |
| `td_groups_test.dart` | `TdGroups` | group id helpers, request shapes, `TdGroupInfo`/`TdMemberStanding` mapping |
| `td_media_test.dart` | `TdMedia` | progress extraction, download/awaitDownloaded, readFilePart, upload seam |
| `td_voice_test.dart` | `TdVoice` | voice/video note wire payloads, reply wrapping, incoming note duration parsing |
| `td_ghost_test.dart` | `TdGhost`, `TdGhostSettings` | defaults/copyWith, online option, ghost suppression, request shapes, backend contract |
| `td_push_test.dart` | `TdPush` | device token wire forms, register/unregister, `TdPushNoop`, unified contract mapping |
| `td_ffi_client_test.dart` | `TdFfiClient` (FFI adapter) | destroy ordering vs receive loop (UAF contract), state errors after destroy, wire json decode, undecodable payloads skipped |

### storage

| Test file | What it covers | Key scenarios |
| --- | --- | --- |
| `per_account_databases_test.dart` | `PerAccountDatabases`, `PerAccountMediaCache`, `LegacyDbMigrator` | network-qualified file names, one DB per account with `foreign_keys` ON, handle reuse, removeAccount cleanup, legacy migration, media cache |
| `spoof_profile_store_test.dart` | `SpoofProfileStore` | storage key naming, preset-based generation, matched model/os pairs, save/load round-trip, isolation, stability, legacy migration |
| `spoof_device_presets_test.dart` | `SpoofDevicePresets` | matched model/os_version pairs, no duplicate models, pinned identity constants, json round-trip with defaults |
| `spoof_bridge_test.dart` | see accounts | profile → upstream shape |

### notifications and unified models

| Test file | What it covers | Key scenarios |
| --- | --- | --- |
| `notification_center_test.dart` | `NotificationCenter` | NewMessage → grouped notification, focused-chat suppression, incoming calls, read/cleanup, badge lifecycle, source-agnostic (no transport source) |
| `unified_chat_test.dart` | `UnifiedChat`, unified message (models) | copyWith identity, event application (newMessage/chatRead), cross-chat/account isolation, preview fallback, connection events |

## Test infrastructure

Shared fakes and mocks in `test/` (not `_test` files, so they are never
collected as suites):

| File | Role |
| --- | --- |
| `fake_max_api.dart` | in-memory `MaxApiLike` for `MaxBackend` tests |
| `in_memory_secure_storage.dart` | in-memory `SecureStorageLike` fake |
| `mock_td_client.dart` | in-memory `TdClientLike`: scripts auth/new-message/chat/file updates plus request/response flow (ok/error/timeout) |

Rule of thumb: a new test that needs a platform plugin should instead go
through the existing seam with one of these fakes; if a new seam is needed,
add the fake next to them.

## Adding tests for a new feature

A new feature lands with tests in its domain — this is how the 308 stay a
map rather than a pile:

1. Find the domain of the change (accounts / backends / storage /
   notifications) and the existing test file that touches the same module
   (`lib/core/<domain>/...`). Extend that file if the module already has
   one; otherwise create `test/<module>_test.dart` in the domain's style
   (see the table above for naming).
2. Drive the module through its seam (fake/mock from "Test
   infrastructure"); never require a device, a plugin, or a live network.
3. Assert wire shapes exactly when the module talks to TDLib or MAX:
   schema-shaped request bodies and fixture updates, in the style of
   `td_messages_test.dart`. After touching Telegram mappings, also run
   `tools/td_schema_check.py`.
4. Run the domain before handover:

```bash
dart test test/<your_file>_test.dart   # the file you touched
dart test                              # the whole suite stays green
```

5. Keep the map true: when you add or rename a test file, add/rename its
   row in the table above in the same change.

## Sanity numbers

- 29 `test/*_test.dart` files, 308 tests, all green on `dart test` (see
  the build & test section of the README).
- Every `test/*_test.dart` file from the repository is listed in the map
  above; cross-check with `ls test/*_test.dart`.
