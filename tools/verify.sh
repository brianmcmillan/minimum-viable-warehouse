#!/usr/bin/env bash
# =====================================================================
# Run every warehouse from a fresh build and record the results in
# VERIFY.md at the repo root.
#
# For each v3_* directory: make clean, make demo, make test. Captures
# each step's exit code and the PASS / FAIL / known-GAP counts printed
# by every suite, plus each suite's CORE / MODEL / GAP summary lines, then
# compares the passed counts with the numbers published under
# "Mutation-tested suites" in README.md, and checks that every suite
# reports the same core total.
#
# Changes no schema, loader or test. The only files it writes are the
# generated build/ and archive/ databases (what make demo always
# writes), VERIFY.md, and the raw logs in verify-logs/.
#
# Written for bash 3.2 (stock macOS): no associative arrays.
# Exit status: 0 if every demo and suite passed, 1 otherwise,
# 2 if sqlite3 is not on PATH.
# =====================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
LOGDIR="$ROOT/verify-logs"
OUT="$ROOT/VERIFY.md"
ESC="$(printf '\033')"
strip_ansi() { sed -E "s/${ESC}\[[0-9;]*m//g"; }

SQLITE_VER="$(sqlite3 --version 2>/dev/null | awk '{print $1}')"
if [ -z "$SQLITE_VER" ]; then
  echo "verify: sqlite3 is not on PATH" >&2; exit 2
fi

# The counts README.md publishes, keyed by directory and suite.
published() {
  case "$1" in
    v3_activity-schema:run_tests)     echo 153 ;;
    v3_anchor:run_tests)              echo 133 ;;
    v3_data-marts:run_tests)          echo 108 ;;
    v3_datavault:run_tests)           echo 324 ;;
    v3_focal-point:run_tests)         echo 212 ;;
    v3_hook:run_tests)                echo 129 ;;
    v3_inmon-3nf:run_tests)           echo 99  ;;
    v3_metrics-mart:run_tests)        echo 236 ;;
    v3_one-big-table:run_tests)       echo 85  ;;
    v3_unified-star-schema:run_tests) echo 145 ;;
    *) echo "" ;;
  esac
}

# Suites in the order `make test` runs them (one per model since the
# core alignment folded Focal's test_archive.sh into its run_tests.sh).
suites_of() {
  case "$1" in
    *) echo "run_tests" ;;
  esac
}

num() { printf ' %s' "$1" | sed -E "s/.*[^0-9]([0-9]+) $2.*/\1/"; }

rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"
ROWS="$LOGDIR/rows.md"; FAILS="$LOGDIR/fails.md"; NOTES="$LOGDIR/notes.md"
CORE_TOTALS="$LOGDIR/core_totals"
: > "$ROWS"; : > "$FAILS"; : > "$NOTES"; : > "$CORE_TOTALS"
overall=0

for dir in v3_*/; do
  d="${dir%/}"
  printf '%-24s' "$d"
  t0=$(date +%s)
  (cd "$d" && make clean) > "$LOGDIR/$d.clean.log" 2>&1; clean_rc=$?
  (cd "$d" && make demo)  > "$LOGDIR/$d.demo.log"  2>&1; demo_rc=$?
  (cd "$d" && make test)  > "$LOGDIR/$d.test.raw"  2>&1; test_rc=$?
  t1=$(date +%s)
  strip_ansi < "$LOGDIR/$d.test.raw" > "$LOGDIR/$d.test.log"
  rm -f "$LOGDIR/$d.test.raw"

  # One summary line per suite: "RESULT: N passed, M failed[, K known gap(s)]"
  # or, after an abort, "N passed, M failed before the abort."
  grep -E 'RESULT: [0-9]+ passed|[0-9]+ passed, [0-9]+ failed before the abort' \
    "$LOGDIR/$d.test.log" > "$LOGDIR/$d.summary" || true

  # The three lines every aligned suite ends with:
  #   CORE : <passed>/<total> passed    MODEL: <passed> passed    GAP  : <n>
  sed -nE 's/^ *CORE : ([0-9]+)\/([0-9]+) passed.*/\1 \2/p' "$LOGDIR/$d.test.log" > "$LOGDIR/$d.core"
  sed -nE 's/^ *MODEL: ([0-9]+) passed.*/\1/p'               "$LOGDIR/$d.test.log" > "$LOGDIR/$d.model"

  set -- $(suites_of "$d"); i=0
  while [ $# -gt 0 ]; do
    s="$1"; shift; i=$((i+1))
    line="$(sed -n "${i}p" "$LOGDIR/$d.summary")"
    pub="$(published "$d:$s")"
    core_line="$(sed -n "${i}p" "$LOGDIR/$d.core")"
    if [ -n "$core_line" ]; then
      read -r cp ct <<< "$core_line"; core="$cp/$ct"; echo "$ct" >> "$CORE_TOTALS"
    else
      core="none"
      echo "- \`$d\` $s printed no CORE line" >> "$NOTES"
    fi
    model="$(sed -n "${i}p" "$LOGDIR/$d.model")"; model="${model:-none}"
    if [ -z "$line" ]; then
      p="?"; f="?"; g="?"; match="no summary"
      echo "- \`$d\` $s printed no summary line; see verify-logs/$d.test.log" >> "$NOTES"
      overall=1
    else
      p="$(num "$line" 'passed')"; f="$(num "$line" 'failed')"
      case "$line" in *"known gap"*) g="$(num "$line" 'known gap')" ;; *) g=0 ;; esac
      case "$line" in *"before the abort"*) echo "- \`$d\` $s aborted: $line" >> "$NOTES" ;; esac
      if [ -z "$pub" ]; then match="n/a"
      elif [ "$p" = "$pub" ]; then match="yes"
      else match="**no**"; fi
      [ "$f" = "0" ] || overall=1
    fi
    echo "| \`$d\` | $s | $p | $f | $core | $model | $g | $demo_rc | $test_rc | ${pub:-none} | $match | $((t1-t0))s |" >> "$ROWS"
  done

  # Cross-check: PASS lines printed vs passed totals reported.
  pass_lines=$(grep -cE '^ *PASS ' "$LOGDIR/$d.test.log")
  reported=0
  while read -r line; do
    [ -n "$line" ] && reported=$((reported + $(num "$line" 'passed')))
  done < "$LOGDIR/$d.summary"
  [ "$pass_lines" = "$reported" ] || \
    echo "- \`$d\`: $pass_lines PASS lines printed, $reported passed reported" >> "$NOTES"

  [ "$clean_rc" = 0 ] || echo "- \`$d\`: make clean exited $clean_rc" >> "$NOTES"
  if [ "$demo_rc" != 0 ]; then
    overall=1
    echo "- \`$d\`: make demo exited $demo_rc; tail of verify-logs/$d.demo.log:" >> "$NOTES"
    tail -5 "$LOGDIR/$d.demo.log" | sed 's/^/      /' >> "$NOTES"
  fi
  [ "$test_rc" = 0 ] || overall=1

  if grep -qE '^ *(FAIL|ABORT|SQL ERROR|XPASS)' "$LOGDIR/$d.test.log"; then
    { echo "### \`$d\`"; echo; echo '```';
      grep -E '^ *(FAIL|ABORT|SQL ERROR|XPASS)' "$LOGDIR/$d.test.log" | head -40;
      echo '```'; echo; } >> "$FAILS"
  fi
  [ "$demo_rc$test_rc" = "00" ] && echo "ok" || echo "FAILED (demo $demo_rc, test $test_rc)"
done

# Every suite must report the same core total (tests/core_spec.tsv).
core_total="$(sort -u "$CORE_TOTALS" | paste -sd, -)"
case "$core_total" in
  ''|*,*) overall=1
          echo "- core totals differ between suites (or none was printed): ${core_total:-none}" >> "$NOTES" ;;
esac

dirty="$(git status --porcelain 2>/dev/null | grep -vE '^\?\? (VERIFY\.md|verify-logs/)' | wc -l | tr -d ' ')"

{
  echo "# Verification run"
  echo
  echo "Generated by \`make verify\`. Do not edit by hand."
  echo
  echo "| Item | Value |"
  echo "| --- | --- |"
  echo "| Run at (UTC) | $(date -u '+%Y-%m-%d %H:%M:%S') |"
  echo "| Commit | $(git rev-parse --short HEAD 2>/dev/null || echo unknown) on $(git branch --show-current 2>/dev/null || echo unknown) |"
  echo "| Machine | $(uname -sm) |"
  echo "| sqlite3 | $SQLITE_VER |"
  echo "| bash | ${BASH_VERSION} |"
  echo "| Overall | $([ "$overall" = 0 ] && echo 'all demos and suites passed' || echo '**failures, see below**') |"
  echo "| Core assertions per suite | ${core_total:-none} (tests/core_spec.tsv) |"
  echo "| Tree changed by the run | $([ "$dirty" = 0 ] && echo no || echo "**yes, $dirty path(s)**") |"
  echo
  echo "## Results"
  echo
  echo "Core is the shared core contract (core assertions passed / total); Model is the model's own assertions passed. Gaps are expected failures: a core GAP marks a core assertion the model cannot pass today (C4b closes them). \"Published\" is the count in README.md under \"Mutation-tested suites\"."
  echo
  echo "| Directory | Suite | Passed | Failed | Core | Model | Gaps | Demo exit | Test exit | Published | Match | Time |"
  echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
  cat "$ROWS"
  echo
  echo "## Notes"
  echo
  if [ -s "$NOTES" ]; then cat "$NOTES"; else echo "None."; fi
  echo
  echo "## Failing assertions"
  echo
  if [ -s "$FAILS" ]; then cat "$FAILS"; else echo "None."; fi
} > "$OUT"

echo
echo "Wrote VERIFY.md (raw logs in verify-logs/)."
exit "$overall"
