#!/usr/bin/env bash
# =====================================================================
# Core alignment check: every suite must emit every core assertion in
# tests/core_spec.tsv exactly once, in spec order.
#
#   tests/check_core.sh                 # every v3_*/tests/run_tests.sh
#   tests/check_core.sh v3_inmon-3nf    # just the named model(s)
#   make core-check                     # same as the first form
#
# It runs each suite and reads the ids from its output (PASS, FAIL, GAP
# and XPASS lines alike: a core GAP still counts as emitted). It fails if
# a suite misses an id, emits one twice, emits them out of order, or
# emits an id the spec does not list. A suite's own pass/fail result is
# not judged here -- `make test` and `make verify` do that.
# =====================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$ROOT/tests/core_spec.tsv"
[ -r "$SPEC" ] || { echo "check_core: $SPEC not found" >&2; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
awk -F'\t' 'NR>1 && $1!="" {print $1}' "$SPEC" > "$WORK/want"
n_want="$(grep -c "" "$WORK/want")"

if [ "$#" -gt 0 ]; then dirs=("$@"); else
  dirs=(); for d in "$ROOT"/v3_*/; do dirs+=("$(basename "$d")"); done; fi

overall=0
for d in "${dirs[@]}"; do
  d="${d%/}"; suite="$ROOT/$d/tests/run_tests.sh"
  printf '%-24s ' "$d"
  [ -x "$suite" ] || { echo "FAIL  no tests/run_tests.sh"; overall=1; continue; }
  (cd "$ROOT/$d" && ./tests/run_tests.sh) 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$WORK/$d.log"
  sed -nE 's/^  (PASS|FAIL|GAP |XPASS) (C[0-9]{2}\.[0-9]+) .*/\2/p' "$WORK/$d.log" > "$WORK/$d.got"
  n_got="$(grep -c "" "$WORK/$d.got")"
  problems=""
  if [ "$n_got" -eq 0 ]; then
    problems="emits no core ids (suite not aligned yet)"
  else
    missing="$(grep -vxF -f "$WORK/$d.got" "$WORK/want" | paste -sd' ' -)"
    extra="$(grep -vxF -f "$WORK/want" "$WORK/$d.got" | paste -sd' ' -)"
    dups="$(sort "$WORK/$d.got" | uniq -d | paste -sd' ' -)"
    [ -n "$missing" ] && problems="$problems missing: $missing;"
    [ -n "$extra" ]   && problems="$problems not in the spec: $extra;"
    [ -n "$dups" ]    && problems="$problems emitted twice: $dups;"
    if [ -z "$problems" ] && ! cmp -s "$WORK/$d.got" "$WORK/want"; then
      first="$(paste -d' ' "$WORK/want" "$WORK/$d.got" | awk '$1!=$2 {print "expected " $1 ", got " $2; exit}')"
      problems=" out of order: $first;"
    fi
  fi
  if [ -z "$problems" ]; then echo "ok    $n_got/$n_want core ids, in order"
  else echo "FAIL $problems"; overall=1; fi
done
exit "$overall"
