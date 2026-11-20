#!/usr/bin/env bash
# =====================================================================
# The cross-model answer matrix: the nine shared questions, asked of all
# ten models at the same moment, and the README's end-state block.
#
#   bash compare/run.sh     (or)     make compare
#
# For each model, in a scratch copy (the working tree is never touched):
#   1. `make demo`: a fresh archive and the six shared deliveries D0..D5;
#   2. the model's own re-point fixture (tests/fixtures/d*_repoint.sql);
#   3. Q1..Q8: the model's own tests/answers/Q<n>.sql, run with the
#      archive attached as `arch` -- the adapters are the suite's files,
#      never second copies;
#   4. Q9: compare/rules/<model>.sh changes the rule P -> PLACED with no
#      reload, then tests/answers/Q9.sql runs.
#
# Every cell gets one label (expected answers: compare/questions.tsv):
#   NATIVE     the answer file has no "-- RAW:" header and does not read
#              `arch.`, and its answer is the expected one;
#   RAW        the file has a "-- RAW: <reason>" header (it reads the
#              archive, or the storage layer under a presentation model),
#              and its answer is the expected one;
#   FINDING    the question cannot be answered as asked: a Q9 rule script
#              printed CANNOT<TAB><reason>, and compare/decisions.tsv
#              records "finding" for that cell. The script then rebuilt
#              from the archive with the new rule; the report says whether
#              that rebuild gives the expected answer;
#   DIFFERENT  the answer is not the expected one, under any label;
#   ERROR      the file reads `arch.` without a "-- RAW:" header (so no
#              archive read is ever labelled NATIVE), a rule script printed
#              CANNOT with no "finding" decision, or the query failed.
# compare/decisions.tsv also says which label each cell should reach at
# the end of C4b; the report lists every cell not there yet (a cell with
# no decision row should be NATIVE).
#
# Writes ANSWERS.md, and the end-state block in README.md between the
# compare:end-state markers. No run time, commit or duration goes into
# either, so a rerun on the same inputs writes the same bytes.
# Written for bash 3.2. Exit status: 0 if every model built and no cell is
# an ERROR, 1 otherwise.
# =====================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$ROOT/compare"
: "${SQLITE:=sqlite3}"; export SQLITE
OUT="$ROOT/ANSWERS.md"
README="$ROOT/README.md"
BEGIN_MARK='<!-- compare:end-state:begin -->'
END_MARK='<!-- compare:end-state:end -->'
TAB="$(printf '\t')"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

"$SQLITE" --version >/dev/null 2>&1 || { echo "compare: sqlite3 is not on PATH" >&2; exit 2; }

# Paths the run changes: the tree is listed now and again after the
# README block is written (tools/tree_state.sh), leaving out ANSWERS.md,
# which the run always writes. README.md counts only when its end-state
# block comes out different.
. "$ROOT/tools/tree_state.sh"
tree_state "$ROOT" ANSWERS.md > "$WORK/tree.before"

# models.tsv: dir, label, customer_view   questions.tsv: id, question, expected
# decisions.tsv: model (label), question, baseline, decision, reason
models(){ awk -F'\t' 'NR>1 && $1!="" {print $1}' "$HERE/models.tsv"; }
mcol(){ awk -F'\t' -v d="$1" -v c="$2" 'NR>1 && $1==d {print $c; exit}' "$HERE/models.tsv"; }
qids(){ awk -F'\t' 'NR>1 && $1!="" {print $1}' "$HERE/questions.tsv"; }
qcol(){ awk -F'\t' -v q="$1" -v c="$2" 'NR>1 && $1==q {print $c; exit}' "$HERE/questions.tsv"; }
dcol(){ awk -F'\t' -v m="$1" -v q="$2" -v c="$3" 'NR>1 && $1==m && $2==q {print $c; exit}' "$HERE/decisions.tsv"; }
mk(){ sed -nE "s/^$2 *\?= *([^ #]+).*/\1/p" "$1/Makefile" | head -1; }

# ---- one model ---------------------------------------------------------
# Writes $WORK/<dir>.res, one line per question:
#   id <TAB> label <TAB> value <TAB> reason <TAB> source
# label: NATIVE | RAW | FINDING | DIFFERENT | ERROR
# source: archive | storage (RAW without arch.) | derived | rebuild (FINDING)
run_model(){ local dir="$1" copy="$WORK/$1" res="$WORK/$1.res" log="$WORK/$1.log"
  local db adb fix q f val label reason src rc rawhdr exp m
  m="$(mcol "$dir" 2)"
  cp -R "$ROOT/$dir" "$copy"; rm -rf "$copy/build" "$copy/archive"
  db="$copy/$(mk "$copy" DB)"; adb="$copy/$(mk "$copy" ARCHIVE_DB)"
  : > "$res"
  if ! (cd "$copy" && make demo) > "$log" 2>&1; then
    printf 'BUILD\tERROR\tmake demo failed\t\t\n' > "$res"; return; fi
  fix="$(ls "$copy"/tests/fixtures/d*_repoint.sql 2>/dev/null | head -1)"
  if [ -z "$fix" ] || ! (cd "$copy" && DB="$db" ARCHIVE_DB="$adb" BATCH_TS='2027-02-01 08:00:00' \
        ./scripts/load_feed.sh "$fix" D6) >> "$log" 2>&1; then
    printf 'BUILD\tERROR\tre-point fixture failed\t\t\n' > "$res"; return; fi
  # The README's end-state line: current customers as ref(email).
  "$SQLITE" "$db" "SELECT group_concat(customer_ref||'('||COALESCE(email,'null')||')',' ')
                   FROM (SELECT * FROM $(mcol "$dir" 3) ORDER BY customer_ref)" \
    > "$WORK/$dir.end" 2>&1
  ask(){ "$SQLITE" -cmd "ATTACH DATABASE '$adb' AS arch" "$db" < "$copy/tests/answers/$1.sql" 2>&1; }
  for q in $(qids); do
    f="$copy/tests/answers/$q.sql"; reason=""; exp="$(qcol "$q" 3)"
    if [ ! -f "$f" ]; then printf '%s\tERROR\tno tests/answers/%s.sql\t\t\n' "$q" "$q" >> "$res"; continue; fi
    if [ "$q" = Q9 ]; then
      reason="$(cd "$copy" && DB="$db" ARCHIVE_DB="$adb" bash "$HERE/rules/$dir.sh" 2>>"$log")"; rc=$?
      if [ "$rc" -ne 0 ]; then printf '%s\tERROR\trule change failed\t\t\n' "$q" >> "$res"; continue; fi
    fi
    val="$(ask "$q")"; rc=$?
    val="$(printf '%s' "$val" | tr '\n' ' ' | sed 's/ *$//')"
    rawhdr="$(sed -n 's/^-- RAW: *//p' "$f" | head -1)"
    if grep -q 'arch\.' "$f"; then src=archive; elif [ -n "$rawhdr" ]; then src=storage; else src=derived; fi
    if [ "$rc" -ne 0 ] || printf '%s' "$val" | grep -q '^\(Parse \)\{0,1\}[Ee]rror'; then
      label=ERROR; reason="the query failed"
    elif [ "$src" = archive ] && [ -z "$rawhdr" ]; then
      label=ERROR; reason="reads arch. without a -- RAW: header"
    elif [ -n "$reason" ]; then
      reason="${reason#CANNOT$TAB}"; src=rebuild
      if [ "$(dcol "$m" "$q" 4)" = finding ]; then label=FINDING
      else label=ERROR; reason="the rule script printed CANNOT, and decisions.tsv has no finding for $m $q"; fi
    elif [ "$val" != "$exp" ]; then label=DIFFERENT
    elif [ -n "$rawhdr" ]; then label=RAW; reason="$rawhdr"
    else label=NATIVE; fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$q" "$label" "$val" "$reason" "$src" >> "$res"
  done; }

printf 'Building ten models in scratch copies'
for d in $(models); do run_model "$d" & done
wait; echo " done."

# ---- the re-point fixtures: logically the same delivery? -----------------
for d in $(models); do
  f="$(ls "$ROOT/$d"/tests/fixtures/d*_repoint.sql | head -1)"
  printf '%s\t%s\t%s\t%s\n' "$d" "${f#$ROOT/}" "$(wc -c < "$f" | tr -d ' ')" \
    "$(grep -v '^[[:space:]]*--' "$f" | grep -v '^[[:space:]]*$' | tr -s ' ' | cksum | awk '{print $1}')"
done > "$WORK/fixtures.tsv"
n_sql="$(cut -f4 "$WORK/fixtures.tsv" | sort -u | grep -c .)"

# ---- the README block -------------------------------------------------------
overall=0
if grep -qF "$BEGIN_MARK" "$README" && grep -qF "$END_MARK" "$README"; then
  { echo '```'
    for d in $(models); do printf '%-8s: %s\n' "$(mcol "$d" 2)" "$(cat "$WORK/$d.end")"; done
    echo '```'; } > "$WORK/block"
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v f="$WORK/block" '
    $0==b { print; while ((getline l < f) > 0) print l; skip=1; next }
    $0==e { skip=0 }
    !skip { print }' "$README" > "$WORK/readme" && cat "$WORK/readme" > "$README"
  echo "Updated the end-state block in README.md."
else
  echo "compare: README.md has no compare:end-state markers; block not written" >&2; overall=1
fi

tree_state "$ROOT" ANSWERS.md > "$WORK/tree.after"
tree_changed "$WORK/tree.before" "$WORK/tree.after" > "$WORK/tree.changed"
tree_n="$(wc -l < "$WORK/tree.changed" | tr -d ' ')"

# ---- the report -------------------------------------------------------------
esc(){ printf '%s' "$1" | sed 's/|/\\|/g'; }
row(){ local l; l="$(awk -F'\t' -v q="$2" '$1==q' "$WORK/$1.res")"
  [ -n "$l" ] || l="$(awk -F'\t' '$1=="BUILD"' "$WORK/$1.res")"; printf '%s' "$l"; }
cell(){ local l label val reason
  l="$(row "$1" "$2")"; label="$(printf '%s' "$l" | cut -f2)"
  val="$(printf '%s' "$l" | cut -f3)"; reason="$(printf '%s' "$l" | cut -f4)"
  case "$label" in
    NATIVE) echo NATIVE ;;
    RAW|FINDING) echo "$label ¹" ;;
    DIFFERENT) echo "DIFFERENT: \`$(esc "$val")\`" ;;
    *) echo "**ERROR**: $(esc "${reason:-$val}")" ;;
  esac; }

{
  echo "# Answer matrix"
  echo
  echo "Generated by \`make compare\` (\`compare/run.sh\`). Do not edit by hand."
  echo
  echo "The nine shared questions, asked of all ten models at the same moment:"
  echo "after the six shared deliveries (D0 to D5) and each model's re-point"
  echo "fixture. Each model answers with its own \`tests/answers/Q<n>.sql\`, the"
  echo "same files its suite asserts. The suites ask each question at its own"
  echo "point in the story (Q7 straight after the D3 tombstone, for example), so a"
  echo "question can pass in a suite and still differ here. C4's matrix is kept"
  echo "unchanged in [\`ANSWERS-baseline.md\`](ANSWERS-baseline.md)."
  echo
  echo "A model passes a question at NATIVE or RAW; the difference stays visible"
  echo "because it is the result."
  echo
  echo "- **NATIVE**: the answer file reads only the model's own derived layer, and"
  echo "  the answer is the expected one in \`compare/questions.tsv\`."
  echo "- **RAW ¹**: the answer file reads the raw archive, or the storage layer"
  echo "  under a presentation model, and says so in a \`-- RAW:\` header; the"
  echo "  answer is the expected one."
  echo "- **FINDING ¹**: the question cannot be answered as asked. The table below"
  echo "  gives the reason and whether a rebuild from the archive answers it."
  echo "- **DIFFERENT**: a wrong answer, shown, under any label."
  echo "- **ERROR**: an archive read without a \`-- RAW:\` header, a CANNOT with no"
  echo "  finding decision in \`compare/decisions.tsv\`, or a failed query."
  echo
  echo "| Item | Value |"
  echo "| --- | --- |"
  echo "| Commit | $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown) on $(git -C "$ROOT" branch --show-current 2>/dev/null || echo unknown) |"
  echo "| sqlite3 | $("$SQLITE" --version | awk '{print $1}') |"
  echo "| Tree changed by the run | $(tree_cell "$tree_n") |"
  echo
  if [ "$tree_n" != 0 ]; then
    echo "Paths the run changed:"
    echo
    sed 's/^/- /' "$WORK/tree.changed"
    echo
  fi
  echo "## Questions"
  echo
  echo "| Id | Question | Expected |"
  echo "| --- | --- | --- |"
  for q in $(qids); do echo "| $q | $(esc "$(qcol "$q" 2)") | \`$(esc "$(qcol "$q" 3)")\` |"; done
  echo
  echo "## Matrix"
  echo
  printf '| |'; for d in $(models); do printf ' %s |' "$(mcol "$d" 2)"; done; echo
  printf '| --- |'; for d in $(models); do printf ' --- |'; done; echo
  for q in $(qids); do
    printf '| %s |' "$q"; for d in $(models); do printf ' %s |' "$(cell "$d" "$q")"; done; echo
  done
  echo
  echo "## ¹ RAW and FINDING: what answers, and why"
  echo
  echo "| Model | Question | Label | What answers | Why | Rebuild from the archive answers it |"
  echo "| --- | --- | --- | --- | --- | --- |"
  for d in $(models); do
    awk -F'\t' '$2=="RAW" || $2=="FINDING"' "$WORK/$d.res" |
    while IFS="$TAB" read -r q label val reason src; do
      case "$src" in
        archive) what="the raw archive" ;;
        storage) what="the storage layer under the presentation model" ;;
        rebuild) what="nothing without a reload" ;;
        *) what="$src" ;;
      esac
      if [ "$label" = FINDING ]; then
        if [ "$val" = "$(qcol "$q" 3)" ]; then rb="yes"; else rb="no: \`$(esc "$val")\`"; fi
      else rb="n/a"; fi
      echo "| $(mcol "$d" 2) | $q | $label | $what | $(esc "$reason") | $rb |"
    done
  done
  echo
  echo "## Against the C4b decisions"
  echo
  echo "Cells whose label is not yet the one \`compare/decisions.tsv\` decides for the"
  echo "end of C4b. A cell with no decision row should be NATIVE."
  echo
  echo "| Model | Question | Now | Decided | Reason |"
  echo "| --- | --- | --- | --- | --- |"
  n_off=0
  for d in $(models); do m="$(mcol "$d" 2)"
    for q in $(qids); do
      now="$(row "$d" "$q" | cut -f2)"
      want="$(dcol "$m" "$q" 4 | tr 'a-z' 'A-Z')"; want="${want:-NATIVE}"
      if [ "$now" != "$want" ]; then
        n_off=$((n_off+1))
        echo "| $m | $q | $now | $want | $(esc "$(dcol "$m" "$q" 5)") |"
      fi
    done
  done
  [ "$n_off" -gt 0 ] || echo "| — | — | — | — | every cell is at its decided label |"
  echo
  echo "## End state"
  echo
  echo "Current customers as \`ref(email)\`, from each model's customer view. The"
  echo "same block is written into README.md."
  echo
  echo '```'
  for d in $(models); do printf '%-8s: %s\n' "$(mcol "$d" 2)" "$(cat "$WORK/$d.end")"; done
  echo '```'
  echo
  echo "## The re-point fixtures"
  echo
  if [ "$n_sql" -eq 1 ]; then
    echo "The ten files differ in size only because their comments differ. With"
    echo "comment and blank lines removed, all ten are the same SQL, so they are"
    echo "logically the same delivery."
  else
    echo "**With comment and blank lines removed, the ten files are not the same SQL**"
    echo "($n_sql different versions): they are not the same delivery."
  fi
  echo
  echo "| Model | File | Bytes | Checksum of the SQL without comments |"
  echo "| --- | --- | --- | --- |"
  while IFS="$TAB" read -r d f b c; do echo "| $(mcol "$d" 2) | \`$f\` | $b | $c |"; done < "$WORK/fixtures.tsv"
} > "$OUT"

for d in $(models); do
  if awk -F'\t' '$2=="ERROR"' "$WORK/$d.res" | grep -q .; then
    awk -F'\t' -v d="$d" '$2=="ERROR" {print "compare: " d " " $1 ": " ($4!="" ? $4 : $3)}' "$WORK/$d.res" >&2
    overall=1
  fi
done
echo "Wrote ANSWERS.md."
exit "$overall"
