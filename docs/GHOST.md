# Ghost modes

Ghost mode suppresses the passive signals a messenger normally emits while the
user is just reading: read receipts, typing indicators and online presence.
It is a **per-account** setting — every MAX and Telegram account carries its
own profile, sessions of other accounts are unaffected.

This document describes what is actually implemented in the two backends, with
the exact code locations, so an owner can reason about what the app does (and
does not) hide on the wire.

## Model

| | MAX | Telegram |
|---|---|---|
| Setting shape | one on/off flag («невидимка») | three independent flags: `ghostRead`, `ghostTyping`, `ghostOnline` |
| Where it lives | `MaxBackend` / upstream invisible mode | `TdGhost` policy holder over the account's `TdBridge` |
| Unified-contract entry point | `MaxBackend.setGhostMode(bool)` (`lib/core/backends/max/max_backend.dart:162`) | `TdSessionManager.setGhostProfile(account, TdGhostSettings)` (`lib/core/backends/telegram/td_sessions.dart:114`); the plain `MessengerBackend.setGhostMode(bool)` (`lib/core/backends/messenger_backend.dart:64`) is not yet implemented for the Telegram side |
| Persistence | in-memory only (re-applied by `SessionManager` state, not stored) | persisted per account as `tg_ghost:<id>` prefs entry, re-applied on session start (`lib/core/backends/telegram/td_sessions.dart:91-128`) |

## Modes × networks × wire effect

The "suppressed on the wire" column names the concrete request that is **not
sent** when the mode is active.

### ghostRead — do not mark messages as read

| Network | Suppressed wire requests | Suppression point |
|---|---|---|
| Telegram | `openChat` and `viewMessages` (with `force_read: true`) — TDLib calls that would push read state to the server | `TdGhost.markRead` returns before any `bridge.send` while `ghostRead` is on (`lib/core/backends/telegram/td_ghost.dart:179-183`); guard predicate `shouldMarkRead` (`:141`); request builders for the non-ghost path (`:149-160`) |
| MAX | **nothing is suppressed** — `markRead` still resolves the last message (`fetchHistory`) and sends `markRead` to the server | `MaxBackend.markRead` does not consult the ghost flag (`lib/core/backends/max/max_backend.dart:133-139`) |

Telegram-side consequence: unread counters stay client-side; the chat store
keeps its local `unread_count` (`lib/core/backends/telegram/td_chat_store.dart:192`),
the server never learns the chat was opened.

### ghostTyping — do not send typing indicators

| Network | Suppressed wire requests | Suppression point |
|---|---|---|
| Telegram | `sendChatAction` (typing and cancel actions alike) | `TdGhost.sendTyping` returns before `bridge.send` while `ghostTyping` is on (`lib/core/backends/telegram/td_ghost.dart:173-176`); guard predicate `shouldSendTyping` (`:144`) |
| MAX | **nothing is suppressed** — `setTyping` still forwards to the api | `MaxBackend.setTyping` does not consult the ghost flag (`lib/core/backends/max/max_backend.dart:142-143`) |

### ghostOnline — do not surface as online

| Network | Mechanism | Suppression point |
|---|---|---|
| Telegram | on enable: `setOption name:"online" = optionValueBoolean{false}` — TDLib stops reporting the account online on activity; on disable: `setOption name:"online" = optionValueEmpty` — returns online management to TDLib's automatic behaviour (a forced `true` would pin the status instead); the option resets on client restart, and `TdGhost.reapplyOnline` is exposed for the reconnect path (not yet wired to a production reconnect call site) | enable/disable: `TdGhost.setGhostMode` (`lib/core/backends/telegram/td_ghost.dart:102-112`), option senders (`:121-136`); re-apply helper: `TdGhost.reapplyOnline` (`:116-119`) |
| MAX | reuses the upstream «невидимка»: `api.setGhostMode` flips the server-side invisible mode, so the server does not see interactive activity (no keep-alive pings while the user is active) | `MaxBackend.setGhostMode` delegates to `api.setGhostMode` and emits a `ghostModeChanged` event (`lib/core/backends/max/max_backend.dart:159-174`) |

## Default semantics

- **Ghost is off by default on both networks.** Ghost is an explicit opt-in:
  - Telegram: `TdGhost` starts with `TdGhostSettings.off` until a profile is
    applied (`lib/core/backends/telegram/td_ghost.dart:84-88`); a stored
    profile is absent by default and `ghostProfileOf` returns `off`
    (`lib/core/backends/telegram/td_sessions.dart:94-110`).
  - MAX: `MaxBackend._ghostMode` starts `false`
    (`lib/core/backends/max/max_backend.dart:33`); `SessionManager._ghostMode`
    starts `false` and applies it to newly started sessions only after the
    user turned it on (`lib/core/app/session_manager.dart:34, 83-85, 119-131`).
- **Telegram `TdGhostSettings` constructor defaults are all-on**
  (`lib/core/backends/telegram/td_ghost.dart:33-37`) — but this is the shape
  of an explicit "full ghost" profile, not the startup state. Startup state is
  always `off` (see above); the all-on constructor is what the unified
  `setGhostMode(true)` maps to.
- **A session raised in ghost never leaks the online status**: the persisted
  Telegram profile is applied right after session start, *before* the account
  is declared live (`lib/core/backends/telegram/td_sessions.dart:161-164`);
  on the MAX side a session started while ghost is on receives
  `setGhostMode(true)` right after resume, before the account becomes active
  (`lib/core/app/session_manager.dart:77-86`).
- Changing the Telegram profile takes effect immediately and is re-consulted
  on every later call — the backend holds no hidden state beyond `settings`
  (`lib/core/backends/telegram/td_ghost.dart:3-5`).

## Interaction with Capabilities

Both networks declare `ghostMode: true` in `Capabilities`
(`lib/core/backends/capabilities.dart:48` for MAX, `:63` for Telegram), so a
unified UI renders the ghost toggle for both. Two caveats follow from the
capability contract:

- The capabilities model is a single `ghostMode` bit. On Telegram the
  underlying profile is three-axis and the UI can expose read/typing/online
  independently; on MAX only the session-level flag exists, so a fine-grained
  toggle must map down to the single bit (all-on / all-off).
- `markRead` and `setTyping` capabilities are `true` on both networks
  (`lib/core/backends/capabilities.dart:43-44, 58-59`), but on Telegram these
  operations become silent no-ops while the corresponding ghost axis is on.
  The capability answers "the backend supports the operation"; the ghost
  profile decides whether it goes on the wire.

## MAX vs Telegram differences

- **Granularity.** MAX ghost is one flag that hides activity at the session
  level (server-side «невидимка» via `pingInteractive`); Telegram ghost is
  three independent flags, each mapped to specific TDLib requests.
- **Read receipts and typing are NOT suppressed on MAX.** `markRead` and
  `setTyping` send their wire calls unconditionally
  (`lib/core/backends/max/max_backend.dart:133-143`); only the
  interactive-presence signal is hidden. On Telegram all three axes are
  suppressed at the request level.
- **Online semantics.** MAX: the server stops seeing interactive pings
  (may still see the connection itself — the session stays logged in and
  receiving pushes). Telegram: an explicit `setOption "online" = false` is
  sent, and TDLib stops reporting online on any activity; the option
  resets on client restart, and `TdGhost.reapplyOnline` is exposed for the
  reconnect path (re-apply, not assume — not yet wired to a production
  reconnect call site) (`lib/core/backends/telegram/td_ghost.dart:114-119`).
- **Persistence.** The Telegram profile survives restarts (`tg_ghost:<id>`
  prefs entry, wire format: three flag characters, e.g. `110` = read+typing
  live — `lib/core/backends/telegram/td_sessions.dart:91-128`).
  The MAX ghost state is in-memory: after an app restart ghost is off until
  the user re-enables it.
- **Notifications about the change.** MAX emits a `ghostModeChanged`
  backend event when the mode flips (`lib/core/backends/max/max_backend.dart:165-171`);
  the notification center currently ignores that event kind
  (`lib/core/notifications/notification_center.dart:80`). The Telegram side
  applies profiles silently, without an equivalent event.
- **Session spec vs runtime call.** On MAX the connection spec pins
  `pingInteractive: true` (`lib/core/backends/max/max_api_seam.dart:249`) —
  ghost is applied as a runtime `api.setGhostMode` call after connect, not
  baked into the session parameters.

## Verification pointers

The behaviours above are covered by unit tests:
`test/td_ghost_test.dart` (suppression, online option, per-axis profiles,
request shapes), `test/td_sessions_test.dart` (profile persistence and the
start-in-ghost invariant), `test/session_manager_test.dart` (a MAX session
started while ghost is on comes up with ghost applied), and
`test/max_backend_test.dart` (the invisible-mode flip and the
`ghostModeChanged` event).
