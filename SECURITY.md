# Security Policy (v0)

This document records the current network-egress policy and security-invariant status for wellmagram. It is a snapshot of the checked `main` source tree; it does not claim runtime enforcement where the code currently provides only a seam or plan.

## 1. Network egress (S1)

The intended allowlist is MAX services, Telegram data centers using MTProto, and FCM only in a future Google-enabled build. The application must not add its own backend, analytics, crash reporting, or telemetry without an explicit security review.

### Endpoints verified in the source tree

| Destination | Purpose | Evidence and status |
|---|---|---|
| `api2.oneme.ru:443` | MAX API session | `lib/core/backends/max/max_api_seam.dart`: `SessionSpec.defaultHost` and `defaultPort`. This is the only production host literal found in Dart source by the host-literal sweep. |
| Telegram data centers | Telegram MTProto | `lib/core/backends/telegram/td_client_seam.dart` passes `use_test_dc` (default false); TDLib selects production endpoints. No Telegram host literal is present in application Dart code. |
| FCM endpoints | Push delivery, intended only for a future Google-enabled build | `lib/core/backends/telegram/td_push.dart` contains TDLib FCM token/push seams, but push-channel wiring and a Google product flavor are not present in the current tree. No FCM hostname is asserted here. |

MAX media destinations are not listed: media URLs are supplied at runtime and no fixed media host was verified in the source tree. They require a runtime network audit before being added to an allowlist.

A user-configured proxy is a transport route, not an additional application service. The MAX session configuration exposes an optional `proxy` field. Verify proxy behavior and destination restrictions before treating an allowlist as runtime-enforced.

### Verification notes

- **Host literal discrepancy**: The initial task specification and planning documents referenced `api.oneme.ru`. In the checked codebase, the actual production default host is `api2.oneme.ru` (`lib/core/backends/max/max_api_seam.dart:168: SessionSpec.defaultHost = 'api2.oneme.ru'`). The literal `api.oneme.ru` does not appear in application code.
- **Occurrence statistics**: Running `grep -rn "api2.oneme.ru" lib test | wc -l` yields exactly 15 occurrences (1 production declaration in `lib/core/backends/max/max_api_seam.dart:168` and 14 occurrences across test suites).
- **Telegram and FCM**: No fixed Telegram DC or FCM hostnames are declared in application code. Telegram MTProto endpoint selection is delegated to TDLib (`libtdjson`), and FCM wiring/Google flavors are absent.
- **Scope**: These statements reflect static source inspection of the codebase; they describe code assertions rather than runtime packet captures.

## 2. Threat model

| Adversary | Concern | Current mitigation or limitation |
|---|---|---|
| MAX service operator | Metadata, client fingerprinting, account restrictions | Per-account spoof-profile and rate-limiter components exist; they do not hide network metadata. |
| Google services | Telemetry in a Google-enabled build | No Google product flavor or FCM channel is wired in the checked tree. Reassess if such a build is added. |
| Local device attacker | Credential and local database disclosure | Credential and TDLib key-storage abstractions exist; verify production secure-storage wiring and platform backup behavior. |
| Network attacker | Traffic interception or endpoint substitution | MAX defaults to TLS port 443; a debug-oriented insecure-TLS option exists. Release enforcement and pinning require separate verification. |
| Other apps on device | Unauthorized IPC or component access | Android manifests define component export boundaries; review every newly exported component and permission. |
| Malicious or compromised project contributor | Malicious code or dependency in a release | Source review and reproducible release practices reduce risk but do not eliminate supply-chain risk. Audit dependency and release changes. |

## 3. Invariants S1-S7

Status describes the checked source tree, not a complete security certification.

| ID | Invariant | Status | Evidence / limitation |
|---|---|---|---|
| S1 | Network access is limited to approved MAX, Telegram, and explicitly enabled push services. | Seam / incomplete enforcement | MAX default endpoint is in `max_api_seam.dart`; TDLib owns Telegram endpoint selection; push is not wired. Runtime egress enforcement is not demonstrated. |
| S2 | Authentication secrets and database keys use secure storage and are never logged. | Seam | Credential/key-store abstractions and content-free logging interfaces exist; verify production plugin wiring and all call sites. |
| S3 | Device-spoof profiles are isolated per account and change only through an intentional user action. | Implemented in current components | Spoof-profile model/store and tests exist; reassess if account or mutation flows change. |
| S4 | No analytics, crash-reporting, or advertising SDKs are included without review. | Current tree appears compliant | Dependency/build configuration inspection found no such SDK references; repeat on dependency changes and release variants. |
| S5 | Runtime permissions are minimal and feature-scoped. | Partial | Current manifests avoid several sensitive permissions; verify the merged manifest for every release variant. |
| S6 | Insecure TLS cannot be enabled in release builds. | Planned / unverified | `SessionSpec.insecureTls` defaults false, but a compile-time release gate has not been demonstrated here. |
| S7 | Users receive clear disclosure of what the service can observe and what data is collected. | Planned | No complete transparency screen/first-run disclosure was verified in the current source snapshot. |

## 4. Logging

Logging should exclude message bodies, phone numbers, credentials, database encryption keys, and authentication hashes. The Telegram bridge exposes a content-free logging interface and a no-op default; verify any production logger before enabling it.

## 5. Follow-up verification

- Perform packet-capture testing against a release build and compare observed destinations with this policy, including media traffic.
- Verify secure-storage wiring, merged-manifest permissions, release TLS configuration, and every dependency's network behavior.
- Revisit FCM and proxy statements if product flavors or transport wiring change.
