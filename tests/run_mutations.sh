#!/usr/bin/env bash
# =====================================================================
# Mutation harness: break the code on purpose and check the suite notices.
#
#   tests/run_mutations.sh v3_inmon-3nf          # one model, table on stdout
#   tests/run_mutations.sh --report MUTATIONS.md # every model; write the report
#   make mutate                                  # same as the second form
#   (cd v3_inmon-3nf && make mutate)             # same as the first form
#
# Each model keeps its mutations in tests/mutations/, one file per
# mutation (*.mut). A file is a block of "key: value" lines:
#
#   name:     short-kebab-name           (required)
#   tag:      shared | model             (required) shared = the delete
#             rule, archive, load control and dedup, which every model
#             implements; model = anything specific to this model
#   file:     path inside the model dir  (required) the file to patch
#   sed:      a sed expression           (one or more) applied in order
#   patch:                               (instead of sed) every line after
#             this one is a unified diff, applied with patch -p1 from the
#             model directory (use a/<path> and b/<path>)
#   what:     one line saying what the mutation breaks (required)
#   survivor: why the suite cannot catch it (optional) -- marks a KNOWN
#             survivor; it is reported, not failed
#
# For each mutation the harness copies the model directory (and the
# shared tests/core_spec.tsv) to a scratch directory, applies the patch,
# checks that the patch changed the file, runs tests/run_tests.sh there,
# and records:
#   KILLED    at least one assertion failed, the suite aborted, or it
#             exited non-zero; the broken assertions are recorded by their
#             core ids (C05.3) or MODEL labels (M05 <label>)
#   SURVIVED  the suite stayed green
#   ERROR     the patch did not apply or changed nothing
# Before any mutation it runs the unmutated suite once in a copy: a red
# baseline makes every KILLED meaningless, so that model is skipped.
#
# The working tree is never patched: every mutation runs in a copy, and
# the harness checks the model directory is byte-identical afterwards.
#
# JOBS (default 4) mutations run at once. Written for bash 3.2.
# Exit status: 0 if every mutation was KILLED or is a known survivor,
# 1 otherwise (an unexpected survivor, an ERROR, a red baseline or a
# changed working tree), 2 on bad usage.
# =====================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$ROOT/tests/core_spec.tsv"
JOBS="${JOBS:-4}"
REPORT=""
ESC="$(printf '\033')"

usage(){ echo "usage: $0 [--report FILE] [v3_model ...]" >&2; exit 2; }
dirs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --report) [ "$#" -ge 2 ] || usage; REPORT="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) dirs+=("${1%/}"); shift ;;
  esac
done
if [ "${#dirs[@]}" -eq 0 ]; then
  for d in "$ROOT"/v3_*/; do dirs+=("$(basename "$d")"); done
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Paths the run changes: the tree is listed now and again after the last
# model (tools/tree_state.sh), leaving out the report the run writes.
# Mutations run in copies, so this should always come out "no".
. "$ROOT/tools/tree_state.sh"
case "$REPORT" in
  '') REPORT_REL=MUTATIONS.md ;;
  /*) REPORT_REL="${REPORT#$ROOT/}" ;;
  *)  REPORT_REL="$REPORT" ;;
esac
tree_state "$ROOT" "$REPORT_REL" > "$WORK/tree.before"

# ---- reading a mutation file ----------------------------------------
# field FILE KEY -> the value of the first "KEY:" line (header only)
field(){ awk -v k="$2" '
  /^patch:[[:space:]]*$/ {exit}
  index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^[[:space:]]+/, "", v); print v; exit }' "$1"; }
# seds FILE -> every sed expression, one per line
seds(){ awk '/^patch:[[:space:]]*$/ {exit}
  index($0, "sed:") == 1 { v = substr($0, 5); sub(/^[[:space:]]+/, "", v); print v }' "$1"; }
# patch_body FILE -> the unified diff after "patch:", if any
patch_body(){ awk 'p {print} /^patch:[[:space:]]*$/ {p=1}' "$1"; }

# Fingerprint of a model's tracked sources, to prove nothing was patched.
fingerprint(){ (cd "$ROOT/$1" && find . -type f \
    -not -path './build/*' -not -path './archive/*' -not -name '.DS_Store' \
    -print0 | sort -z | xargs -0 cksum) | cksum; }

# Copy a model next to its own tests/core_spec.tsv (the suites read
# $PROJ/../tests/core_spec.tsv), without its build/ and archive/.
make_copy(){ local model="$1" dest="$2"
  mkdir -p "$dest/tests"; cp "$SPEC" "$dest/tests/core_spec.tsv"
  cp -R "$ROOT/$model" "$dest/$model"
  rm -rf "$dest/$model/build" "$dest/$model/archive"; }

# Run a suite in a copy: log, exit code.
run_suite(){ local proj="$1" log="$2" rc=0
  # Each run gets its own database pair: parallel runs must not share one.
  ( cd "$proj" && TESTDB="$log.test.db" ./tests/run_tests.sh ) > "$log.raw" 2>&1 || rc=$?
  sed -E "s/${ESC}\[[0-9;]*m//g" "$log.raw" > "$log"
  rm -f "$log.raw" "$log.test.db" "$log.test_archive.db"
  printf '%s' "$rc"; }

# The assertions a run broke, one per line: core ids, "Mnn <label>" for
# model assertions (by the MODEL section they print under), the abort.
broken(){ awk '
  /^== [CM][0-9]+ / { sec = $2 }
  /^  (FAIL|XPASS) / {
    line = $0; sub(/^  (FAIL|XPASS) /, "", line)
    sub(/  \(got .*/, "", line); sub(/ -- the gap appears FIXED.*/, "", line)
    if (match(line, /^C[0-9][0-9]\.[0-9]+ /)) print substr(line, 1, RLENGTH - 1)
    else print sec " " line
  }
  /^  ABORT / { line = $0; sub(/^  ABORT /, "", line); print "ABORT " line }
  /^  FAIL [0-9]+ core assertions ran/ { print "core count: " substr($0, 8) }' "$1"; }

# ---- one mutation ------------------------------------------------------
# Writes $out.{result,broken,detail}.
run_one(){ local model="$1" mut="$2" out="$3"
  local scratch="$out.d" file proj before rc n
  make_copy "$model" "$scratch"; proj="$scratch/$model"
  file="$(field "$mut" file)"
  : > "$out.broken"
  if [ -z "$file" ] || [ ! -f "$proj/$file" ]; then
    echo ERROR > "$out.result"; echo "file '$file' not found" > "$out.detail"; rm -rf "$scratch"; return; fi
  cp "$proj/$file" "$out.orig"
  if [ -n "$(patch_body "$mut")" ]; then
    if ! patch_body "$mut" | (cd "$proj" && patch -p1 -s) > "$out.detail" 2>&1; then
      echo ERROR > "$out.result"; rm -rf "$scratch"; return; fi
    find "$proj" -name '*.orig' -delete
  else
    n=0
    while IFS= read -r expr; do
      [ -n "$expr" ] || continue; n=$((n+1))
      if ! sed -i.mutbak -e "$expr" "$proj/$file" 2> "$out.detail"; then
        echo ERROR > "$out.result"; rm -rf "$scratch"; return; fi
      rm -f "$proj/$file.mutbak"
    done <<< "$(seds "$mut")"
    if [ "$n" -eq 0 ]; then
      echo ERROR > "$out.result"; echo "no sed: and no patch:" > "$out.detail"; rm -rf "$scratch"; return; fi
  fi
  if cmp -s "$out.orig" "$proj/$file"; then
    echo ERROR > "$out.result"; echo "the patch changed nothing in $file" > "$out.detail"
    rm -rf "$scratch"; return; fi
  rc="$(run_suite "$proj" "$out.log")"
  broken "$out.log" > "$out.broken"
  if [ "$rc" -ne 0 ] || [ -s "$out.broken" ]; then
    echo KILLED > "$out.result"
    [ -s "$out.broken" ] || echo "suite exited $rc" > "$out.broken"
  else
    echo SURVIVED > "$out.result"
  fi
  : > "$out.detail"; rm -rf "$scratch"; }

# ---- one model -----------------------------------------------------------
# Writes $WORK/<model>/rows.tsv: name, tag, result, known, broken (joined with "; ").
overall=0
run_model(){ local model="$1" mdir="$WORK/$1" mut base rc i=0 fp_before fp_after
  local muts=() m
  mkdir -p "$mdir"
  for m in "$ROOT/$model"/tests/mutations/*.mut; do [ -e "$m" ] && muts+=("$m"); done
  if [ "${#muts[@]}" -eq 0 ]; then echo "none" > "$mdir/status"; return; fi
  printf '%-24s baseline ' "$model"
  fp_before="$(fingerprint "$model")"
  mkdir -p "$mdir/base"; make_copy "$model" "$mdir/base"
  rc="$(run_suite "$mdir/base/$model" "$mdir/base.log")"; rm -rf "$mdir/base"
  if [ "$rc" -ne 0 ]; then
    echo "RED (exit $rc) -- skipped"; echo "red" > "$mdir/status"; overall=1; return; fi
  echo "green; ${#muts[@]} mutation(s)"
  echo "ran" > "$mdir/status"
  # Run JOBS at a time.
  local running=0
  for mut in "${muts[@]}"; do
    i=$((i+1))
    run_one "$model" "$mut" "$mdir/$(printf '%03d' "$i")" &
    running=$((running+1))
    if [ "$running" -ge "$JOBS" ]; then wait; running=0; fi
  done
  wait
  : > "$mdir/rows.tsv"; i=0
  for mut in "${muts[@]}"; do
    i=$((i+1)); base="$mdir/$(printf '%03d' "$i")"
    local name tag result known brk what
    name="$(field "$mut" name)"; tag="$(field "$mut" tag)"; what="$(field "$mut" what)"
    known="$(field "$mut" survivor)"
    result="$(cat "$base.result" 2>/dev/null || echo ERROR)"
    if [ "$result" = ERROR ]; then brk="$(tr '\n' ' ' < "$base.detail" 2>/dev/null)"
    else brk="$(paste -sd';' "$base.broken" | sed 's/;/; /g')"; fi
    case "$result" in
      KILLED)   [ -z "$known" ] || { result="KILLED (marked survivor)"; overall=1; } ;;
      SURVIVED) [ -n "$known" ] || overall=1 ;;
      *)        overall=1 ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$tag" "$result" "$known" "$brk" "$what" \
      "$(basename "$mut")" >> "$mdir/rows.tsv"
    printf '  %-34s %-6s %-9s %s\n' "$name" "$tag" "$result" \
      "$([ "$result" = SURVIVED ] && { [ -n "$known" ] && echo "(known: $known)" || echo "<-- UNEXPECTED SURVIVOR"; } || echo "$brk" | cut -c1-90)"
  done
  fp_after="$(fingerprint "$model")"
  if [ "$fp_before" != "$fp_after" ]; then
    echo "  WORKING TREE CHANGED during the run -- the harness must never patch it"
    echo "changed" > "$mdir/tree"; overall=1
  fi; }

for d in "${dirs[@]}"; do
  [ -d "$ROOT/$d" ] || { echo "no such model: $d" >&2; exit 2; }
  run_model "$d"
done

tree_state "$ROOT" "$REPORT_REL" > "$WORK/tree.after"
tree_changed "$WORK/tree.before" "$WORK/tree.after" > "$WORK/tree.changed"
tree_n="$(wc -l < "$WORK/tree.changed" | tr -d ' ')"
if [ "$tree_n" != 0 ]; then
  echo "The run changed $tree_n path(s) in the work tree:"; sed 's/^/  /' "$WORK/tree.changed"
fi

# ---- the report ------------------------------------------------------------
if [ -n "$REPORT" ]; then
  case "$REPORT" in /*) ;; *) REPORT="$ROOT/$REPORT" ;; esac
  {
    echo "# Mutation run"
    echo
    echo "Generated by \`make mutate\` (\`tests/run_mutations.sh\`). Do not edit by hand."
    echo
    echo "Each mutation is one file in \`v3_*/tests/mutations/\`. The harness applies it to a"
    echo "scratch copy of the model, runs that model's \`tests/run_tests.sh\`, and records"
    echo "KILLED when at least one assertion fails (or the suite aborts) and SURVIVED when"
    echo "the suite stays green. The working tree is never patched."
    echo "\`shared\` mutations break the plumbing every model shares: the delete rule, the"
    echo "archive, load control and dedup. \`model\` mutations break something only that"
    echo "model has. Broken assertions are core ids (\`tests/core_spec.tsv\`) or MODEL"
    echo "labels, prefixed with the MODEL section they print under."
    echo
    echo "| Item | Value |"
    echo "| --- | --- |"
    echo "| Run at (UTC) | $(date -u '+%Y-%m-%d %H:%M:%S') |"
    echo "| Commit | $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown) on $(git -C "$ROOT" branch --show-current 2>/dev/null || echo unknown) |"
    echo "| sqlite3 | $(sqlite3 --version 2>/dev/null | awk '{print $1}') |"
    echo "| Overall | $([ "$overall" = 0 ] && echo 'every mutation killed or a known survivor' || echo '**unexpected survivors or errors, see below**') |"
    echo "| Tree changed by the run | $(tree_cell "$tree_n") |"
    echo
    if [ "$tree_n" != 0 ]; then
      echo "Paths the run changed:"
      echo
      sed 's/^/- /' "$WORK/tree.changed"
      echo
    fi
    echo "## Summary"
    echo
    echo "| Model | Mutations | Shared | Model | Killed | Known survivors | Unexpected |"
    echo "| --- | --- | --- | --- | --- | --- | --- |"
    for d in "${dirs[@]}"; do
      st="$(cat "$WORK/$d/status" 2>/dev/null || echo none)"
      case "$st" in
        none) echo "| \`$d\` | not yet covered | | | | | |" ;;
        red)  echo "| \`$d\` | baseline red, skipped | | | | | |" ;;
        *) awk -F'\t' -v d="$d" '
             { n++; if ($2=="shared") s++; else m++
               if ($3=="KILLED") k++
               else if ($3=="SURVIVED" && $4!="") ks++
               else u++ }
             END { printf "| `%s` | %d | %d | %d | %d | %d | %d |\n", d, n, s, m, k, ks, u }' \
             "$WORK/$d/rows.tsv" ;;
      esac
    done
    for d in "${dirs[@]}"; do
      [ "$(cat "$WORK/$d/status" 2>/dev/null)" = ran ] || continue
      echo
      echo "## \`$d\`"
      echo
      echo "| Mutation | Tag | What it breaks | Result | Assertions broken |"
      echo "| --- | --- | --- | --- | --- |"
      awk -F'\t' '
        function esc(s) { gsub(/\|/, "\\|", s); return s }
        { res = $3; if (res=="SURVIVED" && $4!="") res = "SURVIVED (known)"
          else if (res=="SURVIVED") res = "**SURVIVED**"
          else if (res!="KILLED") res = "**" res "**"
          printf "| `%s` | %s | %s | %s | %s |\n", $1, $2, esc($6), res, esc($3=="SURVIVED" ? "none" : $5) }' \
        "$WORK/$d/rows.tsv"
      if awk -F'\t' '$3=="SURVIVED"' "$WORK/$d/rows.tsv" | grep -q .; then
        echo
        echo "Survivors:"
        echo
        awk -F'\t' '$3=="SURVIVED" { printf "- `%s` (`tests/mutations/%s`): %s\n", $1, $7, ($4!="" ? $4 : "**unexpected: no assertion catches it**") }' \
          "$WORK/$d/rows.tsv"
      fi
      [ -e "$WORK/$d/tree" ] && { echo; echo "**The working tree changed during this model's run.**"; }
    done
  } > "$REPORT"
  echo
  echo "Wrote $(basename "$REPORT")."
fi
exit "$overall"
