# Repository tools

## `td_schema_check.py` — TDLib wire-schema gate

Machine-checks every TDLib json field name used by wellmagram against the
official `td_api.tl` schema, so a fabricated or misspelled wire field (the
`can_invite_users_by_link` bug class, review a35a3932) fails a cheap static
check instead of silently breaking a Telegram request at runtime.

### What it checks

- `lib/core/backends/telegram/td_*.dart` (production): map keys of every
  `{...}` literal, attributed to its own `'@type'` constructor, **and** index
  reads like `json['field']`, checked against the union of all constructor
  fields.
- `test/mock_td_client.dart` and `test/td_*_test.dart` (fixtures): map keys of
  wire-shaped literals — fixtures are wire forms too, so a wrong fixture
  fails the same way as wrong production code.
- Deliberate exceptions are encoded in the script: legacy constructors kept
  for older TDLib versions (ADR-0001), well-known non-wire keys, and
  negative fixtures marked with `// td_schema_check: NEGATIVE_FIXTURE`.

### How to run

```sh
# 1. Fetch the schema (pin a TDLib ref if you target a specific version):
curl -sL -o /tmp/td_api.tl \
  https://raw.githubusercontent.com/tdlib/td/master/td/generate/scheme/td_api.tl

# 2. Run the check (default schema path is /tmp/td_api.tl):
python3 tools/td_schema_check.py /tmp/td_api.tl        # one-line summary
python3 tools/td_schema_check.py --report /tmp/td_api.tl  # per-file/constructor summary
python3 tools/td_schema_check.py --quiet /tmp/td_api.tl   # silent when green
```

Modes:

| flag       | behaviour                                                        |
| ---------- | ---------------------------------------------------------------- |
| *(none)*   | one-line summary: `N field names verified … OK: no mismatches`    |
| `--report` | human-readable summary per file and per constructor (CI gate too) |
| `--quiet`  | no output when nothing mismatches; failures still print           |

Exit code is **0 = verified, 1 = mismatches found** in every mode, so the
plain invocation is directly CI-usable:

```sh
python3 tools/td_schema_check.py --report /tmp/td_api.tl || exit 1
```

### What to do on failure

1. Read the `MISMATCHES:` lines — each names the file, the constructor, and
   the offending field (or `index read <name> exists in no constructor`).
2. Fix the field name in the Dart code (or fixture) to the real wire name
   from `td_api.tl` — check the constructor's definition in the schema.
3. If the mismatch is an *intentionally wrong* name in a negative test
   fixture, add the `// td_schema_check: NEGATIVE_FIXTURE` marker comment to
   that file and register the key in `NEGATIVE_FIXTURE_KEYS` in the script.
4. Re-run until the exit code is 0; `flutter test` must stay green too.

Run this check whenever a change touches Telegram API mappings — see
`CONTRIBUTING.md` and the checklist in `README.md`.
