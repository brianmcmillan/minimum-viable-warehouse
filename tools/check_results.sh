#!/usr/bin/env bash
# =====================================================================
# Compare the RESULTS in VERIFY.md, MUTATIONS.md and ANSWERS.md with the
# committed copies (git HEAD). Results only, never the environment.
#
#   VERIFY.md     the Results table, columns Directory, Suite, Passed,
#                 Failed, Gaps, Demo exit, Test exit and Published. The
#                 header table (run time, commit, machine, sqlite3 and
#                 bash versions, overall, tree changed) and the Time
#                 column are not compared.
#   MUTATIONS.md  the Summary table, and the Mutation, Tag and Result
#                 columns of each model's table. Not the "Item | Value"
#                 header table (run time, commit, sqlite3 version,
#                 overall), nor "What it breaks" or "Assertions broken":
#                 which assertions a mutation breaks first, and the exit
#                 code a killed load reports, vary with the sqlite3
#                 version.
#   ANSWERS.md    every table except the "Item | Value" header table
#                 (commit, sqlite3 version, tree changed; before C6 a
#                 one-row "sqlite3" table), and the End state block.
#
# Each compared row is printed as "<file> | <section> | <row>". On a
# mismatch the differing rows are printed, committed copy first, and the
# script exits 1. Exit 2: not in a git work tree, or a file is missing.
# Written for bash 3.2 and POSIX awk.
#   usage: tools/check_results.sh
# =====================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
git rev-parse --verify -q HEAD >/dev/null || { echo "check_results: no git HEAD to compare with" >&2; exit 2; }

# VERIFY.md: the table whose first header cell is "Directory"; the named
# columns only, found by header name.
extract_verify(){ awk -v want="Directory|Suite|Passed|Failed|Gaps|Demo exit|Test exit|Published" '
  function trim(s){ sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  BEGIN { nw = split(want, w, "|") }
  /^\|/ {
    n = split($0, c, "|")
    if (!intab) { intab = 1; keep = (trim(c[2]) == "Directory")
      if (keep) { for (i = 2; i < n; i++) col[trim(c[i])] = i
                  for (j = 1; j <= nw; j++) if (!(w[j] in col)) { print "MISSING COLUMN " w[j]; keep = 0 } } }
    if (!keep || $0 ~ /^\| *---/) next
    row = ""; for (j = 1; j <= nw; j++) row = row (j > 1 ? " | " : "") trim(c[col[w[j]]])
    print "VERIFY.md | Results | " row; next }
  { intab = 0 }'; }

# MUTATIONS.md and ANSWERS.md: every table but the environment ones
# (first header cell "Item" or "sqlite3"), plus fenced blocks, each line
# tagged with its "## " section.
extract_tables(){ awk -v file="$1" '
  function trim(s){ sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  /^## / { sec = substr($0, 4) }
  /^```/ { fence = !fence; next }
  fence  { print file " | " sec " | " $0; next }
  /^\|/ {
    split($0, c, "|")
    if (!intab) { intab = 1; first = trim(c[2]); keep = (first != "Item" && first != "sqlite3") }
    if (!keep || $0 ~ /^\| *---/) next
    print file " | " sec " | " $0; next }
  { intab = 0 }'; }

# MUTATIONS.md: the Summary table whole; in each model's table only the
# Mutation, Tag and Result columns, found by header name. What a
# mutation breaks first, and the exit code a killed load reports, depend
# on the sqlite3 version, so "Assertions broken" is not compared.
extract_mutations(){ awk '
  function trim(s){ sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  /^## / { sec = substr($0, 4) }
  /^```/ { fence = !fence; next }
  fence  { next }
  /^\|/ {
    n = split($0, c, "|")
    if (!intab) { intab = 1; keep = (trim(c[2]) != "Item"); mut = 0
      if (keep) for (i = 2; i < n; i++) col[trim(c[i])] = i
      if (keep && ("Mutation" in col)) mut = 1
      if (mut && !(("Tag" in col) && ("Result" in col))) { print "MISSING COLUMN Tag/Result in " sec; keep = 0 } }
    if (!keep || $0 ~ /^\| *---/) next
    if (mut) print "MUTATIONS.md | " sec " | " trim(c[col["Mutation"]]) " | " trim(c[col["Tag"]]) " | " trim(c[col["Result"]])
    else     print "MUTATIONS.md | " sec " | " $0
    next }
  { intab = 0; split("", col) }'; }

extract(){ case "$1" in
  VERIFY.md)    extract_verify ;;
  MUTATIONS.md) extract_mutations ;;
  *)            extract_tables "$1" ;;
esac; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
rc=0
for f in VERIFY.md MUTATIONS.md ANSWERS.md; do
  [ -f "$f" ] || { echo "check_results: $f is missing (run make all)" >&2; rc=2; continue; }
  git show "HEAD:$f" > "$WORK/committed" 2>/dev/null \
    || { echo "check_results: $f is not committed" >&2; rc=2; continue; }
  extract "$f" < "$WORK/committed" > "$WORK/a"
  extract "$f" < "$f"              > "$WORK/b"
  if [ ! -s "$WORK/b" ]; then
    echo "check_results: no results found in $f" >&2; rc=1; continue; fi
  if cmp -s "$WORK/a" "$WORK/b"; then
    printf '%-13s same results as the committed copy (%s rows)\n' "$f" "$(wc -l < "$WORK/b" | tr -d ' ')"
  else
    printf '%-13s DIFFERS from the committed copy:\n' "$f"
    diff "$WORK/a" "$WORK/b" | sed -n 's/^< /  committed: /p; s/^> /  this run:  /p'
    [ "$rc" -eq 0 ] && rc=1
  fi
done
exit "$rc"
