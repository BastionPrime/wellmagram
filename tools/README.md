# tools/

Repository tools. Run from the repo root with the Dart SDK from the build
image (or any Dart >= 3.10).

- `td_schema_check.py` — machine-checks the TDLib json field names used by
  the code and test fixtures against the official `td_api.tl`:
  `python3 tools/td_schema_check.py [path-to-td_api.tl]` (exit 0 = all
  names verified).
- `ffi_smoke.dart` — live smoke of the production TDLib FFI adapter
  (`lib/core/backends/telegram/td_ffi_client.dart`): the full
  create → receive → updateAuthorizationState(authorizationStateWaitTdlibParameters)
  → close → clean-teardown cycle with timings, exit code 0/1:
  `dart run tools/ffi_smoke.dart <path-to-libtdjson> [--timeout seconds]
  [--verbose]` (the library path may also come from `WM_TD_JSON_LIB`;
  pass a library matching the host architecture — the bundled
  `jniLibs/arm64-v8a` binary is Android-only).
