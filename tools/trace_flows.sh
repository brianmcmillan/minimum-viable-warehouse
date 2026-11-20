#!/usr/bin/env bash
# =====================================================================
# Trace the call graph of the Makefiles and scripts, statically.
#
#   tools/trace_flows.sh               one indented tree per target: the
#                                      root Makefile, the CI workflow, and
#                                      every v3_*/Makefile
#   tools/trace_flows.sh --check       fail if a script or schema file a
#                                      make target runs is named in no
#                                      level-2 flow diagram or table
#   tools/trace_flows.sh --confirm M [T ...]
#                                      run `make T` (default: demo test)
#                                      for model M in a scratch copy with
#                                      bash tracing on, and fail if the run
#                                      called a script or read a schema
#                                      file that M's tree for T lacks
#   tools/trace_flows.sh --orphans     scripts in the repo no target runs
#
# What counts as a call, in a Makefile recipe or a script (comment lines
# and echo/printf lines are skipped):
#   ./scripts/X.sh  ./tests/X.sh  ../tests/X.sh  tools/X.sh  tests/X.sh
#   compare/X.sh  "$(dirname "$0")/X.sh"  $PROJ/... $WORK/proj/...
#   $ROOT/...  (a script; "(sourced)" when the line sources it)
#   schema/NN_name.sql                     (a schema file the script reads)
#   rules/$x.sh                            (compare/rules/<model>.sh)
#   $(MAKE) ... target                     (another target, same Makefile)
#   ... && make target                     (make in each v3_* directory)
#   make -C "$PROJ" target                 (a target of the same model)
#   tests/answers/, tests/fixtures/        (the SQL the suites run)
# A path is kept only if the file exists. A model path named from a root
# script (./tests/run_tests.sh in tools/verify.sh) is drawn once as
# v3_*/..., not expanded: each model's own tree has it. A file already
# drawn in the same tree is printed again with "(as above)".
#
# Exit: 0; 1 if --check or --confirm finds a gap; 2 on a usage error.
# Written for bash 3.2 and POSIX awk; --confirm traces fully with bash
# 4.1 or later on PATH and falls back to logging each script it starts.
# =====================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
DIAGRAMS="flow-diagrams/mermaid/repo-targets.md flow-diagrams/mermaid/model-pipeline.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TAB="$(printf '\t')"

# ---- extraction ------------------------------------------------------
# Print "kind<TAB>raw<TAB>sourced" for every call on the given lines.
extract(){ awk '
  function emit(kind, re, s,   t) {
    t = s
    while (match(t, re)) {
      print kind "\t" substr(t, RSTART, RLENGTH) "\t" src
      t = substr(t, RSTART + RLENGTH) } }
  /^[ \t]*#/ { next }
  /^[ \t@]*(echo|printf)[ \t]/ { next }
  { src = ($0 ~ /(^|[;&(|]|then|do|else)[ \t@]*(source|\.)[ \t]+[^ \t=]/) ? 1 : 0
    emit("sh", "\\$\\(dirname \"\\$0\"\\)/[A-Za-z0-9_]+\\.sh", $0)
    emit("sh", "(\\$[A-Z_]+/|\\$WORK/proj/|\\.\\./|\\./)?(scripts|tests|tools|compare)/[A-Za-z0-9_]+\\.sh", $0)
    emit("rules", "rules/\\$[A-Za-z_{}]+\\.sh", $0)
    emit("sql", "schema/[0-9A-Za-z_]+\\.sql", $0)
    emit("answers", "(tests|\\$HERE)/answers/", $0)
    emit("fixtures", "(tests|\\$HERE)/fixtures", $0)
    emit("make", "&& make [a-z][a-z-]*", $0)
    emit("selfmake", "make( -[a-zA-Z]+)* -C \"?\\$PROJ\"? [a-z][a-z-]*", $0)
    emit("submake", "\\$\\(MAKE\\)[^|;]* [a-z][a-z-]*[ \t]*(\\|\\||;|$)", $0) }'; }

model_of(){ case "$1" in v3_*/*) echo "${1%%/*}" ;; *) echo "" ;; esac; }

# Resolve one raw match from FILE to a node: a repo path, "v3_*/<rel>"
# (generic), "@make <t>" (make in each model), "@target <t>" (same
# Makefile). Prints nothing if it resolves to no file.
resolve(){ local file="$1" kind="$2" raw="$3" d m rel p
  d="$(dirname "$file")"; m="$(model_of "$file")"
  case "$kind" in
    make)    echo "@make ${raw##* }"; return ;;
    selfmake) [ -n "$m" ] && echo "@target ${raw##* }"; return ;;
    submake) raw="${raw%%|*}"; raw="${raw%%;*}"; set -- $raw; eval "p=\${$#}"
             echo "@target $p"; return ;;
    rules)   ls compare/rules/*.sh >/dev/null 2>&1 && echo "compare/rules/<model>.sh"; return ;;
    answers) echo "${m:-v3_*}/tests/answers/Q1..Q9.sql"; return ;;
    fixtures) echo "${m:-v3_*}/tests/fixtures/*.sql"; return ;;
    sql)     [ -n "$m" ] && [ -f "$m/$raw" ] && echo "$m/$raw"; return ;;
  esac
  case "$raw" in
    '$(dirname "$0")/'*) p="$d/${raw#*)/}" ;;
    ../tests/*)          p="tests/${raw#../tests/}" ;;
    '$ROOT/'*)           p="${raw#\$ROOT/}" ;;
    '$PROJ/'*)           rel="${raw#\$PROJ/}";      p="${m:+$m/}$rel"; [ -n "$m" ] || p="v3_*/$rel" ;;
    '$WORK/proj/'*)      rel="${raw#\$WORK/proj/}"; p="${m:+$m/}$rel"; [ -n "$m" ] || p="v3_*/$rel" ;;
    '$'*)                rel="${raw#*/}";           p="${m:+$m/}$rel"; [ -n "$m" ] || p="$rel" ;;
    *)                   rel="${raw#./}"
                         if [ -n "$m" ]; then p="$m/$rel"; else p="$rel"; fi ;;
  esac
  case "$p" in v3_\*/*) ls $p >/dev/null 2>&1 && echo "$p"; return ;; esac
  if [ -f "$p" ]; then echo "$p"
  elif [ -z "$m" ] && ls v3_*/"$rel" >/dev/null 2>&1; then echo "v3_*/$rel"; fi; }

# The calls FILE makes, one "node<TAB>sourced" per line, first-seen order.
refs(){ local f="$1" key; key="$TMP/refs.$(echo "$f" | tr '/' '_')"
  if [ ! -f "$key" ]; then
    extract < "$f" | while IFS="$TAB" read -r kind raw src; do
      resolve "$f" "$kind" "$raw" | while IFS= read -r n; do
        [ "$n" = "$f" ] || printf '%s\t%s\n' "$n" "$src"; done
    done | awk -F'\t' '!seen[$1]++' > "$key"
  fi
  cat "$key"; }

# Makefile MF: the recipe lines of TARGET.
recipe(){ awk -v t="$2" '
  /^[A-Za-z][A-Za-z0-9_.-]*:/ && !/:=/ { split($0, a, ":"); intgt = (a[1] == t); next }
  /^\t/ && intgt { print; next }
  /^[^\t]/ { intgt = 0 }' "$1"; }
targets(){ awk '/^[A-Za-z][A-Za-z0-9_-]*:/ && !/:=/ && !/^\.PHONY/ { split($0, a, ":"); print a[1] }' "$1"; }

# Calls a target makes: its recipe, as a pseudo-file.
target_refs(){ local mf="$1" t="$2" key; key="$TMP/tref.$(echo "$mf.$t" | tr '/' '_')"
  if [ ! -f "$key" ]; then
    recipe "$mf" "$t" > "$TMP/recipe"
    local pseudo; pseudo="$(dirname "$mf")/Makefile"; [ "$pseudo" = "./Makefile" ] && pseudo=Makefile
    extract < "$TMP/recipe" | while IFS="$TAB" read -r kind raw src; do
      resolve "$pseudo" "$kind" "$raw"; done | awk '!seen[$0]++' > "$key"
  fi
  cat "$key"; }

# ---- tree ------------------------------------------------------------
# walk NODE INDENT TAG MAKEFILE SEENFILE
walk(){ local node="$1" ind="$2" tag="$3" mf="$4" seen="$5" n s
  case "$node" in
    @target\ *) printf '%smake %s\n' "$ind" "${node#@target }"
                target_refs "$mf" "${node#@target }" | while IFS= read -r n; do
                  walk "$n" "$ind  " "" "$mf" "$seen"; done; return ;;
    @make\ *)   printf '%smake %s  (in each v3_* directory; see its tree)\n' "$ind" "${node#@make }"; return ;;
    v3_\*/*) # in a model's own tree, the generic path is that model's file
             if [ -n "$CURMODEL" ] && [ -f "$CURMODEL/${node#v3_*/}" ]; then node="$CURMODEL/${node#v3_*/}"
             else printf '%s%s%s\n' "$ind" "$node" "$tag"; return; fi ;;
    *'<model>'*|*Q1..Q9*|*'*.sql') printf '%s%s%s\n' "$ind" "$node" "$tag"; return ;;
  esac
  if grep -qxF "$node" "$seen"; then printf '%s%s%s  (as above)\n' "$ind" "$node" "$tag"; return; fi
  echo "$node" >> "$seen"
  printf '%s%s%s\n' "$ind" "$node" "$tag"
  case "$node" in *.sql) return ;; esac
  refs "$node" | while IFS="$TAB" read -r n s; do
    if [ "$s" = 1 ]; then walk "$n" "$ind  " "  (sourced)" "$mf" "$seen"
    else walk "$n" "$ind  " "" "$mf" "$seen"; fi; done; }

tree_of(){ local mf="$1" t="$2" seen="$TMP/seen.$$.$RANDOM" n
  CURMODEL="$(model_of "$mf")"; : > "$seen"
  target_refs "$mf" "$t" | while IFS= read -r n; do walk "$n" "  " "" "$mf" "$seen"; done
  rm -f "$seen"; }

ci_targets(){ awk '/^[ \t]*-? *run:/ { r = 1 } r && /make [a-z]/ && !/echo/ {
    while (match($0, /make [a-z][a-z-]*/)) { print substr($0, RSTART + 5, RLENGTH - 5); $0 = substr($0, RSTART + RLENGTH) } }' \
    .github/workflows/ci.yml | awk '!s[$0]++'; }

print_all(){ local mf t
  for t in $(targets Makefile); do
    echo "== Makefile: make $t"; tree_of Makefile "$t"; tree_of_empty Makefile "$t"; echo; done
  for t in $(ci_targets); do
    echo "== .github/workflows/ci.yml: job all runs make $t"
    echo "  make $t  (Makefile: make $t, above)"; echo; done
  for mf in v3_*/Makefile; do
    for t in $(targets "$mf"); do
      echo "== $mf: make $t"; tree_of "$mf" "$t"; tree_of_empty "$mf" "$t"; echo; done
  done; }
tree_of_empty(){ [ -n "$(target_refs "$1" "$2")" ] || echo "  (runs no script)"; }

# Every node reachable from any target: "<makefile-dir>\t<node>".
reachable(){ local mf t
  for mf in Makefile v3_*/Makefile; do
    for t in $(targets "$mf"); do tree_of "$mf" "$t"; done
  done | sed -E 's/^ +//; s/  \((sourced|as above)\)//g; s/  \(sourced\)  \(as above\)//' |
    grep -vE '^make |^\(' | awk '!s[$0]++'; }

# ---- --check ---------------------------------------------------------
check(){ local rc=0 f m cell base
  for f in $DIAGRAMS; do [ -f "$f" ] || { echo "trace_flows: $f is missing" >&2; return 2; }; done
  # Per-model text: the model-pipeline table's column for each model,
  # found by its header (the directory name without v3_).
  awk -F'|' '
    /^\| *Step/ { for (i = 2; i < NF; i++) { h = $i; gsub(/[ `*]/, "", h); col[i] = h }; intab = 1; next }
    intab && /^\|/ { if ($0 ~ /^\| *---/) next; for (i = 2; i < NF; i++) if (i in col) print col[i] "\t" $i; next }
    { intab = 0 }' flow-diagrams/mermaid/model-pipeline.md > "$TMP/cells"
  reachable > "$TMP/reach"
  while IFS= read -r f; do
    case "$f" in
      v3_\*/*|*'<model>'*|*Q1..Q9*|*'*.sql') continue ;;
      v3_*/*.sh|v3_*/*.sql)
        m="${f%%/*}"; m="${m#v3_}"; base="${f##*/}"
        awk -F'\t' -v m="$m" -v b="$base" '$1 == m && index($2, b) { found = 1 } END { exit !found }' "$TMP/cells" ||
          { echo "NOT IN DIAGRAMS  $f  (no cell in the $m column of model-pipeline.md names $base)"; rc=1; } ;;
      *.sh)
        grep -qF "$f" flow-diagrams/mermaid/repo-targets.md ||
          { echo "NOT IN DIAGRAMS  $f  (repo-targets.md does not name it)"; rc=1; } ;;
    esac
  done < "$TMP/reach"
  [ "$rc" = 0 ] && echo "trace_flows: every script and schema file a target runs is in the level-2 diagrams ($(grep -cE '\.(sh|sql)$' "$TMP/reach") checked)."
  return "$rc"; }

# ---- --orphans -------------------------------------------------------
orphans(){ reachable > "$TMP/reach"
  git ls-files '*.sh' | while IFS= read -r f; do
    grep -qxF "$f" "$TMP/reach" && continue
    case "$f" in compare/rules/*) grep -qF 'compare/rules/<model>.sh' "$TMP/reach" && continue ;; esac
    echo "$f"; done; }

# ---- --confirm -------------------------------------------------------
confirm(){ local model="$1"; shift; local targets="${*:-demo test}" t rc=0 work log
  [ -f "$model/Makefile" ] || { echo "trace_flows: no $model/Makefile" >&2; return 2; }
  work="$TMP/confirm"; mkdir -p "$work"
  cp -R "$model" "$work/"; rm -rf "$work/$model/build" "$work/$model/archive"
  mkdir -p "$work/tests"; cp tests/core_spec.tsv tests/run_mutations.sh "$work/tests/"
  [ -d tools ] && cp -R tools "$work/"
  log="$TMP/trace.log"
  if [ "$(bash -c 'echo "${BASH_VERSINFO[0]}${BASH_VERSINFO[1]}"')" -ge 41 ]; then
    printf '%s\n' 'exec 19>>"$TRACE_LOG"; BASH_XTRACEFD=19' \
      "PS4='+@\${BASH_SOURCE#\${BASH_SOURCE%/*/*}/}@ '" 'set -x' > "$TMP/bashenv"; how="bash -x (BASH_XTRACEFD)"
  else
    # bash 3.2 cannot send the trace to its own descriptor, and $0 is not
    # yet the script while BASH_ENV runs: log $0 at the first command.
    printf '%s\n' 'trap '"'"'printf "+@%s@\n" "${0#${0%/*/*}/}" >> "$TRACE_LOG"; trap - DEBUG'"'"' DEBUG' \
      > "$TMP/bashenv"; how="each script's start (bash 3.2; sourced files not seen)"
  fi
  for t in $targets; do
    : > "$log"
    ( cd "$work/$model" && BASH_ENV="$TMP/bashenv" TRACE_LOG="$log" make "$t" ) > "$TMP/run.$t.out" 2>&1 \
      || echo "  (make $t exited non-zero; tracing what ran)"
    grep -oE '\+@[^@]+@' "$log" | sed 's/^+@//; s/@$//' | grep -E '\.sh$' | sort -u > "$TMP/ran"
    grep -oE 'schema/[0-9A-Za-z_]+\.sql' "$log" | sort -u >> "$TMP/ran"
    tree_of "$model/Makefile" "$t" | sed -E 's/^ +//; s/  \(.*$//' | sed "s#^$model/##" | sort -u > "$TMP/tree"
    if [ ! -s "$TMP/ran" ]; then echo "$model make $t: the trace captured nothing; cannot confirm"; rc=1; continue; fi
    local missing; missing="$(comm -23 <(sort -u "$TMP/ran") "$TMP/tree")"
    printf '%s make %-8s %3d script(s) and schema file(s) ran, traced by %s: ' "$model" "$t" "$(sort -u "$TMP/ran" | wc -l | tr -d ' ')" "$how"
    if [ -z "$missing" ]; then echo "all in the tree"
    else echo "MISSING from the tree:"; echo "$missing" | sed 's/^/    /'; rc=1; fi
  done
  return "$rc"; }

case "${1:-}" in
  "")          print_all ;;
  --check)     check ;;
  --orphans)   orphans ;;
  --confirm)   shift; [ $# -ge 1 ] || { echo "usage: $0 --confirm v3_<model> [target ...]" >&2; exit 2; }; confirm "$@" ;;
  *)           echo "usage: $0 [--check | --orphans | --confirm v3_<model> [target ...]]" >&2; exit 2 ;;
esac
