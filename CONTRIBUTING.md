# Contributing to wellmagram

## Workflow

1. Every change starts with a ticket in the project tracker. The team lead
   breaks it down and assigns an engineer.
2. The engineer implements in a separate branch cut from a **fresh `main`**
   (re-fetch before branching; rebase onto `origin/main` before pushing if
   `main` moved).
3. The engineer opens a pull request against `main` (one branch — one PR) and
   reports in the PR description per the "PR report" section below.
4. The reviewer (review pool) reads the diff against `main` and either
   approves or returns it with concrete findings.
5. The release engineer merges (`git merge --no-ff`) and pushes `main` to
   origin (and to the local mirror). Authors do not merge their own PRs.

### Filler tasks

Small self-contained tasks from the filler queue follow the same flow with two
extras:

- Branch name is `filler-<topic>` (e.g. `filler-account-registry-events`);
  one branch = one ticket.
- A fork (roadmap) task always preempts a filler task: if one lands mid-work,
  return the ticket to `todo` unassigned with a one-line progress note.

## Branches and PRs

- Branch name = short topic + hyphenated description
  (`seam-td-push-registration`, `filler-notification-center-tests`).
- One branch — one change; don't mix unrelated edits. Keep PRs small
  (~up to 800 changed lines, generated code excluded).
- The PR base is `main`. If your change needs CI to run before the CI workflow
  reaches `main`, it is acceptable to rebase onto a branch that carries
  `.github/workflows/ci.yml` and state that in the PR — the merge base stays
  `main`.
- The PR title and body must not contain internal ticket numbers, internal
  hostnames, or team/role names (see "What stays internal" below). A plain
  English topic summary is the title; the tracker linkage lives in the
  tracker, not in GitHub.

## Required checks before a PR

Run these from the repo root and quote the command plus the key output line in
the PR description:

- `flutter analyze` — must exit 0 ("No issues found!");
- `flutter test` — all tests must pass (quote the final line, e.g.
  `00:25 +318: All tests passed!`);
- for changes touching TDLib wire mappings (`lib/core/backends/telegram/**`):
  `tools/td_schema_check.py` must pass (field names cross-checked against the
  official TDLib `td_api.tl`; see `tools/README.md`);
- for packaging/gradle changes: `flutter build apk --debug` must succeed.

Checks run in a container/build image with Flutter pinned to the repo version
(see `docs/BUILD.md`); do not run heavy builds on the local host. A docs-only
change may skip the analyze/test runs, but must say so explicitly in the PR
description ("docs-only, no behavior change").

## Frozen paths

The following paths are frozen upstream-derived code. Edits are allowed only
with explicit owner approval, and then only minimal ones (they ease periodic
upstream merges):

- `lib/backend/**`
- `lib/core/protocol/**`
- `lib/core/transport/**`

Note: parts of these trees are still being ported; where a path does not yet
exist, its future ported counterpart inherits the freeze. New work goes into
new modules and seams (e.g. `lib/core/backends/**`), not into frozen code. If
your task seems to require touching a frozen path, stop and escalate to the
lead instead of working around the rule. The PR description must state that
frozen paths are untouched (a `git diff --stat` quote is enough).

## PR report format

Every PR description follows this template (concise; use GitHub-relative file
paths, no internal identifiers):

```
## Thinking Path
Why this change exists; what was audited/asked; what the code answers.

## What Changed
File-by-file: new tests, fixtures, docs; production code only when the task
required it. State explicitly when production code is untouched.

## Verification
Commands run and their output:
- flutter analyze / flutter test (quote the final line)
- any task-specific scripts
Where they ran (container/build image, Flutter version).

## Risks
Behavior gaps or pinned-but-not-fixed issues; explicit non-claims
(e.g. "not a claim of multi-isolate safety").

## Checklist
- [ ] Tests added where applicable; full flutter test green
- [ ] Frozen paths untouched
- [ ] No secrets, internal hostnames, or internal ticket references
- [ ] Branch cut from fresh main; one branch = one change
```

## Definition of done

- `flutter analyze` clean and `flutter test` green for the touched modules
  (see "Required checks before a PR");
- the PR description follows the report format above and says what problem it
  solves and how it was verified (command + output);
- no secrets, no internal hostnames/paths, no internal ticket numbers in the
  diff, commit messages, branch names, or PR descriptions;
- the branch is pushed to origin and the PR is open, awaiting review —
  merging and publishing are done by the release engineer, not the author;
- after the merge, a live `git ls-remote origin main` confirms `main` moved
  (release engineer's step).

## What stays internal (the "don't leak" list)

This repository may be read outside the team that builds it. Never put into
files, commit messages, branch names, or PR descriptions:

- internal ticket/tracker numbers or links to internal chats and directives;
- internal hostnames, IP addresses, or file paths of internal machines;
- names of internal teams, agents, or role handles.

Reference work via GitHub-native Issues/PRs (`#123`). New commit messages
reference GitHub issues, not internal task IDs.

## Git remotes

- Origin is GitHub (`https://github.com/BastionPrime/wellmagram.git`),
  authentication via managed credentials (profile token + `~/.git-credentials`);
  never print or commit the token.
- The local bare repository is remote `mirror` — fallback and clone seed.
  Push your branch to origin (GitHub) for the PR; the mirror is updated by the
  release flow after merge.
- Every merge to `main` and every release tag is pushed to origin immediately,
  in the same session where it was made. "Done" without a push to origin is
  not done.
- Force-push is forbidden; history is never rewritten. If internal data leaks
  into a pushed tree, fix the HEAD with a new commit and report to the owner.
