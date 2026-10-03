#!/usr/bin/env bash
# Coverage gate for wellmagram (filler task, see queue issue).
#
# Runs `flutter test --coverage`, parses coverage/lcov.info into a
# per-directory summary for lib/core/* (line %) and prints the top-5
# least covered files.
#
# CI-friendly by default: always exits 0 and prints the summary to stdout.
# Pass `--min-line N` (e.g. --min-line 80) to fail with exit 1 when the
# total line coverage is below N percent.
#
# Usage:
#   tools/coverage.sh                 # run tests + print summary, exit 0
#   tools/coverage.sh --min-line 80   # same, but exit 1 if coverage < 80%
#   tools/coverage.sh --summary-only  # reuse coverage/lcov.info, no test run
#
# Requires: flutter in PATH. Runs from any cwd; cd's to the repo root.
set -u

repo_root=$(cd "$(dirname "$0")/.." && pwd)
lcov_rel="coverage/lcov.info"

min_line=""
summary_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --min-line)
      if [ $# -lt 2 ]; then echo "usage error: --min-line needs a value" >&2; exit 2; fi
      min_line="$2"; shift 2 ;;
    --min-line=*)
      min_line="${1#--min-line=}"; shift ;;
    --summary-only)
      summary_only=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *)
      echo "usage error: unknown option '$1'" >&2
      echo "usage: tools/coverage.sh [--min-line N] [--summary-only]" >&2
      exit 2 ;;
  esac
done
if [ -n "$min_line" ] && ! printf '%s' "$min_line" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
  echo "usage error: --min-line expects a number, got '$min_line'" >&2
  exit 2
fi

# --- Parse summary from lcov (plain awk, no gawk extensions) -------------
# Emits: per-directory table, total, and top-5 least covered files.
parse_summary() {
  # 1) collect per-file stats as "file<TAB>covered<TAB>total" lines
  awk '
    function flush() {
      if (file != "" && tot > 0) printf "%s\t%d\t%d\n", file, hit, tot
      file = ""; hit = 0; tot = 0
    }
    /^SF:/ { flush(); file = substr($0, 4); next }
    /^DA:/ { tot++; split($0, a, ","); if (a[2] > 0) hit++; next }
    END { flush() }
  ' "$1"
}

awk_coverage() {
  # per-directory aggregation + total; reads the file-stats TSV on stdin
  awk -F'\t' '
    function pct(h, t) { return t > 0 ? sprintf("%.1f", 100 * h / t) : "n/a" }
    {
      n = split($1, parts, "/")
      if (n >= 3 && parts[1] == "lib" && parts[2] == "core") {
        dir = "lib/core/" parts[3]
      } else {
        dir = parts[1]
        for (i = 2; i < n; i++) dir = dir "/" parts[i]
      }
      dhit[dir] += $2; dtot[dir] += $3
      thit += $2; ttot += $3
    }
    END {
      printf "%-32s %8s %8s %8s\n", "directory", "lines", "covered", "line %"
      for (d in dhit) printf "%-32s %8d %8d %7s%%\n", d, dtot[d], dhit[d], pct(dhit[d], dtot[d])
      printf "%-32s %8d %8d %7s%%\n", "TOTAL", ttot, thit, pct(thit, ttot)
    }
  '
}

# --- Optionally run the tests ---------------------------------------------
if [ "$summary_only" -eq 0 ]; then
  if ! command -v flutter >/dev/null 2>&1; then
    echo "coverage: flutter not found in PATH" >&2
  else
    (
      cd "$repo_root" || exit 1
      # The repo pins the flutter SDK package via dependency_overrides to
      # /opt/flutter/packages/flutter (build-image path). Outside the build
      # image, point the override at the running SDK for this run only and
      # restore the file afterwards.
      override_backup=""
      if [ "$(dirname "$(dirname "$(command -v flutter)")")" != "/opt" ] \
         && grep -q 'path: /opt/flutter/packages/flutter' pubspec.yaml; then
        override_backup=$(mktemp)
        cp pubspec.yaml "$override_backup"
        sed -i "s|path: /opt/flutter/packages/flutter|path: $(dirname "$(dirname "$(command -v flutter)")")/packages/flutter|" pubspec.yaml
      fi
      restore() { if [ -n "$override_backup" ]; then mv "$override_backup" pubspec.yaml; fi }
      trap restore EXIT
      flutter test --coverage || \
        echo "coverage: flutter test reported failures; summary may be partial" >&2
    )
  fi
fi

lcov_abs="$repo_root/$lcov_rel"
if [ ! -f "$lcov_abs" ]; then
  echo "coverage: $lcov_rel not found (run without --summary-only first)" >&2
  exit 0
fi

# --- Summary ---------------------------------------------------------------
stats=$(parse_summary "$lcov_abs")

printf '%s\n' "$stats" | awk_coverage

echo
echo "top 5 least covered files (lowest line % first):"
printf '%s\n' "$stats" | awk -F'\t' '{
    if ($3 > 0) printf "%.6f\t%s\t%d\t%d\n", $2 / $3, $1, $2, $3
  }' | sort -n | head -5 | cut -f2- | \
  awk -F'\t' '{
    pct = $3 > 0 ? sprintf("%.1f", 100 * $2 / $3) : "n/a"
    printf "  %-55s %6d/%-6d %6s%%\n", $1, $2, $3, pct
  }'

# --- Optional threshold ----------------------------------------------------
if [ -n "$min_line" ]; then
  total_pct=$(printf '%s\n' "$stats" | awk -F'\t' 'END { if (NR > 0) printf "%.2f", 100 * s / t; else printf "0" } { s += $2; t += $3 }')
  pass=$(awk -v got="$total_pct" -v want="$min_line" 'BEGIN { print (got + 0 >= want + 0) ? "yes" : "no" }')
  if [ "$pass" != "yes" ]; then
    echo "coverage: total line coverage ${total_pct}% is below --min-line ${min_line}%" >&2
    exit 1
  fi
  echo "coverage: total line coverage ${total_pct}% meets --min-line ${min_line}%"
fi
