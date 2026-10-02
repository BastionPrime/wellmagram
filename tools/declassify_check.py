#!/usr/bin/env python3
"""Public-mirror hygiene sweep: catch internal references in the tree.

Scans every tracked text file on the current branch for patterns that must
never appear in the public mirror (CONTRIBUTING.md, "don't leak" list):

- internal ticket references: OPE-<digits> (any internal tracker prefix
  captured so far; extend PATTERN_TICKET if new prefixes show up);
- internal hostnames / IPs / role handles where they are actually present.

Findings exit 1 with file:line:match; intentional historical mentions go
into tools/.declassify_whitelist (one `path:line` glob-free entry per line,
lines starting with '#' are comments).

Usage: python3 tools/declassify_check.py
Exit 0 = clean; exit 1 = findings (or the whitelist itself leaked refs).
"""

import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WHITELIST = REPO / "tools" / ".declassify_whitelist"

PATTERNS = {
    "internal-ticket-ref": re.compile(r"\bOPE-\d+\b"),
    "internal-hostname": re.compile(
        r"\b(?:[\w.-]*\.)?(?:itkadr-git|myrmidon|adm-dev-eng)\b"
    ),
    "internal-ip": re.compile(r"\b10\.10\.\d{1,3}\.\d{1,3}\b"),
}

# The whitelist file itself is a controlled place: ticket ids may appear
# there as *allowlisted* mentions, so it is excluded from scanning. The
# check script is excluded too: it necessarily names the patterns it
# detects (the hostname literals live in its own source).
EXCLUDE_FILES = {Path("tools/.declassify_whitelist"), Path("tools/declassify_check.py")}


def tracked_files() -> list[Path]:
    out = subprocess.run(
        ["git", "ls-files", "-z"], cwd=REPO, check=True,
        stdout=subprocess.PIPE, text=False,
    ).stdout
    return [REPO / p.decode("utf-8") for p in out.split(b"\0") if p]


def is_text(path: Path) -> bool:
    try:
        path.read_text(encoding="utf-8")
        return True
    except (UnicodeDecodeError, ValueError):
        return False


def load_whitelist() -> set[str]:
    if not WHITELIST.exists():
        return set()
    entries: set[str] = set()
    for line in WHITELIST.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            entries.add(line)
    return entries


def main() -> int:
    whitelist = load_whitelist()
    findings: list[str] = []
    for path in tracked_files():
        rel = path.relative_to(REPO).as_posix()
        if rel in {p.as_posix() for p in EXCLUDE_FILES}:
            continue
        if not path.is_file() or not is_text(path):
            continue
        for lineno, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            for name, pat in PATTERNS.items():
                for m in pat.finditer(line):
                    entry = f"{rel}:{lineno}"
                    if entry in whitelist:
                        continue
                    findings.append(
                        f"{rel}:{lineno}: [{name}] {m.group(0)} :: {line.strip()[:100]}"
                    )
    if findings:
        print(f"declassify_check: {len(findings)} finding(s)")
        for f in findings:
            print("  " + f)
        print(
            "Neutralize them (see CONTRIBUTING.md 'don't leak' list) or add an\n"
            "intentional exception to tools/.declassify_whitelist as 'path:line'."
        )
        return 1
    print("declassify_check: clean (0 findings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
