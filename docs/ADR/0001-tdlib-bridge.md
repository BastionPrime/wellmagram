# ADR-0001: Bridge between Dart and TDLib (libtdjson)

- Status: accepted-provisionally
- Date: 2026-10-02
- Supersedes: —
- Related: upcoming ADR-0002 (push delivery), ADR-0003 (parallel sessions)

## Context

The Telegram backend talks to TDLib through the JSON client seam
(`lib/core/backends/telegram/td_client_seam.dart`, interface `TdClientLike`)
whose contract mirrors the official `td_json_client.h` C API:
`create / send / receive / execute / destroy`, with `receive` owning a
dedicated receive thread/isolate and preserving TDLib's update order.

Two implementation options for that seam were considered:

- (i) Dart FFI binding to `libtdjson` loaded in-process;
- (ii) a Kotlin JNI plugin with a platform-channel bridge.

Facts on record today (code + CHANGELOG "Live verification" milestone):

- Option (i) is implemented and works: the production adapter
  `lib/core/backends/telegram/td_ffi_client.dart` binds
  `td_json_client_send/execute/destroy` via `DynamicLibrary.open`, runs
  `receive` in a dedicated Dart isolate, and forwards updates in arrival
  order. Teardown is hardened against use-after-free: `destroy()` sends
  `close`, sets a stop-flag checked between receive iterations (timeout
  ≤ 1 s, terminal `authorizationStateClosed` exits earlier), and runs the
  native `td_json_client_destroy` inside the receive isolate strictly
  after the loop exits — `receive` and `destroy` never run in parallel on
  one client.
- A live smoke against the real `libtdjson` (built from source, arm64-v8a,
  shipped in `jniLibs/`) passed: `create → receive →
  updateAuthorizationState(authorizationStateWaitTdlibParameters)` with a
  9 ms cold start and a clean teardown.
- The full test suite is green at 308 unit tests, including
  `test/td_ffi_client_test.dart`, which validates the
  create/send/execute/destroy contract (and the teardown ordering) at the
  structural level via injected fake native functions.
- Option (ii) is not implemented: no Kotlin JNI plugin exists in the tree.

The CHANGELOG explicitly keeps the bridge choice open until comparative
live metrics on a real device exist.

## Decision

We adopt option (i) — the Dart FFI adapter — as the working bridge between
the Telegram backend and TDLib, and record the decision as
**accepted-provisionally**: FFI is the only implemented and verified option,
so all further backend work builds on it, but the final
FFI-vs-Kotlin-JNI decision is deferred until the measurement checklist
below is completed on a real device with a real account. The seam
(`TdClientLike`) stays the single integration point, so a later switch of
the bridge implementation stays local to the seam's adapters.

## Alternatives considered

| # | Alternative | Status | Notes |
|---|-------------|--------|-------|
| (i) | Dart FFI over `libtdjson` (`td_ffi_client.dart`) | working implementation, live-verified (9 ms cold-start smoke, teardown UAF-hardened) | adopted provisionally |
| (ii) | Kotlin JNI plugin + platform channel | not implemented | revisit only if the E3 checklist below shows FFI failing a criterion in a way a JNI bridge would plausibly fix |

## Consequences

Positive:

- One language across core and bridge (no Kotlin/Java hop for updates),
  ordered update stream delivered directly into Dart.
- Teardown lifecycle is fully under Dart control; the UAF risk found in
  review is covered by tests.
- The decision is reversible: the seam interface means the bridge can be
  replaced without touching auth/chats/messages/media layers.

Negative / accepted risks:

- JNI alternative has no implementation and no data; the comparison is
  FFI-measured vs JNI-hypothetical until the E3 checklist runs.
- In-process native library means a native crash takes down the whole
  Flutter app (a JNI bridge would not change this; it is inherent to
  embedding TDLib).

Obligations created:

- Run the E3 measurement checklist before declaring the bridge choice
  final; keep this ADR's status in sync with the outcome.
- Any new bridge implementation must keep the `TdClientLike` contract and
  the teardown ordering guarantees.

## Status & finalization criteria

Current status: `accepted-provisionally`.

Checklist to finalize (metrics on a real device with a real account, FFI vs
the same workload profile; record results here and flip status to
`accepted` or open a superseding ADR if (ii) must be built):

- [ ] Cold start: time from process start to first `updateAuthorizationState`
      (baseline today: 9 ms in the build-image smoke; repeat on-device).
- [ ] Update latency: end-to-end delay of an incoming message update from
      TDLib `receive` to the Dart-side stream consumer, measured over a
      session with real traffic.
- [ ] Stability: 1-hour live session, no leaks (RSS stable), no missed
      updates, no teardown failures.
- [ ] UI at scale: chats-list screen with 200 chats scrolls and updates
      without jank attributable to the bridge (frame timeline recorded).

Expected follow-ups, using the ADR template (0000): ADR-0002 on push
delivery, ADR-0003 on parallel session mode.
