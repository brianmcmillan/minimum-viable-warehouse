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
# Each cell is SAME (the expected answer in compare/questions.tsv),
# DIFFERENT (with the value) or CANNOT (with the reason), where:
#   * an answer file that reads the archive (`arch.`) is a question the
#     derived layer cannot answer: CANNOT, with the one-line reason from
#     the file's "-- CANNOT: <reason>" header, and the archive column says
#     whether the archive's answer is the expected one;
#   * a rule script that prints CANNOT<TAB><reason> is a model whose rule
#     cannot change without a reload; it then rebuilds from the archive
#     with the new rule, and the archive column records that answer.
#
# Writes ANSWERS.md, and the end-state block in README.md between the
# compare:end-state markers. No run time or commit goes into either, so a
# rerun on the same inputs writes the same bytes.
# Written for bash 3.2. Exit status: 0 if every model built, 1 otherwise.
# =====================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$ROOT/compare"
: "${SQLITE:=sqlite3}"; export SQLITE
OUT="$ROOT/ANSWERS.md"
README="$ROOT/README.md"
BEGIN_MARK='<!-- compare:end-state:begin -->'
END_MARK='<!-- compare:end-state:end -->'
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

"$SQLITE" --version >/dev/null 2>&1 || { echo "compare: sqlite3 is not on PATH" >&2; exit 2; }

# models.tsv: dir, label, customer_view   questions.tsv: id, question, expected
models(){ awk -F'\t' 'NR>1 && $1!="" {print $1}' "$HERE/models.tsv"; }
mcol(){ awk -F'\t' -v d="$1" -v c="$2" 'NR>1 && $1==d {print $c; exit}' "$HERE/models.tsv"; }
qids(){ awk -F'\t' 'NR>1 && $1!="" {print $1}' "$HERE/questions.tsv"; }
qcol(){ awk -F'\t' -v q="$1" -v c="$2" 'NR>1 && $1==q {print $c; exit}' "$HERE/questions.tsv"; }
mk(){ sed -nE "s/^$2 *\?= *([^ #]+).*/\1/p" "$1/Makefile" | head -1; }

# ---- one model ---------------------------------------------------------
# Writes $WORK/<dir>.res, one line per question:
#   id <TAB> kind <TAB> value <TAB> reason
# kind: derived | archive (the answer file reads arch.) | rule (Q9 rebuilt) | error
run_model(){ local dir="$1" copy="$WORK/$1" res="$WORK/$1.res" log="$WORK/$1.log"
  local db adb fix q f val kind reason rc
  cp -R "$ROOT/$dir" "$copy"; rm -rf "$copy/build" "$copy/archive"
  db="$copy/$(mk "$copy" DB)"; adb="$copy/$(mk "$copy" ARCHIVE_DB)"
  : > "$res"
  if ! (cd "$copy" && make demo) > "$log" 2>&1; then
    echo "BUILD	error	make demo failed	see the log" > "$res"; return; fi
  fix="$(ls "$copy"/tests/fixtures/d*_repoint.sql 2>/dev/null | head -1)"
  if [ -z "$fix" ] || ! (cd "$copy" && DB="$db" ARCHIVE_DB="$adb" BATCH_TS='2027-02-01 08:00:00' \
        ./scripts/load_feed.sh "$fix" D6) >> "$log" 2>&1; then
    echo "BUILD	error	re-point fixture failed	see the log" > "$res"; return; fi
  # The README's end-state line: current customers as ref(email).
  "$SQLITE" "$db" "SELECT group_concat(customer_ref||'('||COALESCE(email,'null')||')',' ')
                   FROM (SELECT * FROM $(mcol "$dir" 3) ORDER BY customer_ref)" \
    > "$WORK/$dir.end" 2>&1
  ask(){ "$SQLITE" -cmd "ATTACH DATABASE '$adb' AS arch" "$db" < "$copy/tests/answers/$1.sql" 2>&1; }
  for q in $(qids); do
    f="$copy/tests/answers/$q.sql"; reason=""
    if [ ! -f "$f" ]; then printf '%s\terror\tno tests/answers/%s.sql\t\n' "$q" "$q" >> "$res"; continue; fi
    if [ "$q" = Q9 ]; then
      reason="$(cd "$copy" && DB="$db" ARCHIVE_DB="$adb" bash "$HERE/rules/$dir.sh" 2>>"$log")"; rc=$?
      if [ "$rc" -ne 0 ]; then printf '%s\terror\trule change failed\t\n' "$q" >> "$res"; continue; fi
    fi
    val="$(ask "$q")"; rc=$?
    val="$(printf '%s' "$val" | tr '\n' ' ' | sed 's/ *$//')"
    if [ "$rc" -ne 0 ] || printf '%s' "$val" | grep -q '^\(Parse \)\{0,1\}[Ee]rror'; then kind=error
    elif [ -n "$reason" ]; then kind=rule; reason="${reason#CANNOT	}"
    elif grep -q 'arch\.' "$f"; then kind=archive
      # The reason is the file's own "-- CANNOT: <reason>" header line.
      reason="$(sed -n 's/^-- CANNOT: *//p' "$f" | head -1)"
      [ -n "$reason" ] || reason="the answer reads the raw archive (no -- CANNOT: line in the file)"
    else kind=derived; fi
    printf '%s\t%s\t%s\t%s\n' "$q" "$kind" "$val" "$reason" >> "$res"
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

# ---- the report -------------------------------------------------------------
esc(){ printf '%s' "$1" | sed 's/|/\\|/g'; }
overall=0
cell(){ local d="$1" q="$2" line kind val reason exp
  line="$(awk -F'\t' -v q="$q" '$1==q' "$WORK/$d.res")"
  [ -n "$line" ] || line="$(awk -F'\t' '$1=="BUILD"' "$WORK/$d.res")"
  kind="$(printf '%s' "$line" | cut -f2)"; val="$(printf '%s' "$line" | cut -f3)"
  reason="$(printf '%s' "$line" | cut -f4)"; exp="$(qcol "$q" 3)"
  case "$kind" in
    derived) if [ "$val" = "$exp" ]; then echo SAME; else echo "DIFFERENT: \`$(esc "$val")\`"; fi ;;
    archive|rule) echo "CANNOT ¹" ;;
    *) echo "**ERROR**: $(esc "$val")" ;;
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
  echo "question can pass in a suite and still differ here."
  echo
  echo "- **SAME**: the expected answer in \`compare/questions.tsv\`."
  echo "- **DIFFERENT**: another answer, shown."
  echo "- **CANNOT ¹**: the derived layer cannot answer; see the table below for the"
  echo "  reason and for whether the raw archive can."
  echo
  echo "| sqlite3 | $("$SQLITE" --version | awk '{print $1}') |"
  echo "| --- | --- |"
  echo
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
  echo "## ¹ CANNOT: why, and whether the archive can answer"
  echo
  echo "| Model | Question | Why the derived layer cannot | Archive can answer |"
  echo "| --- | --- | --- | --- |"
  for d in $(models); do
    awk -F'\t' '$2=="archive" || $2=="rule"' "$WORK/$d.res" | while IFS="$(printf '\t')" read -r q kind val reason; do
      exp="$(qcol "$q" 3)"
      if [ "$val" = "$exp" ]; then a="yes"; else a="no: \`$(esc "$val")\`"; fi
      [ "$kind" = rule ] && a="$a (rebuilt from the archive with the new rule)"
      echo "| $(mcol "$d" 2) | $q | $(esc "$reason") | $a |"
    done
  done
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
  while IFS="$(printf '\t')" read -r d f b c; do echo "| $(mcol "$d" 2) | \`$f\` | $b | $c |"; done < "$WORK/fixtures.tsv"
} > "$OUT"

# ---- the README block -------------------------------------------------------
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

for d in $(models); do
  if awk -F'\t' '$1=="BUILD"' "$WORK/$d.res" | grep -q .; then
    echo "compare: $d did not build; see ANSWERS.md" >&2; overall=1; fi
done
echo "Wrote ANSWERS.md."
exit "$overall"
