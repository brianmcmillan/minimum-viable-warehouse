# =====================================================================
# Which paths did a run change? Sourced by tools/verify.sh,
# tests/run_mutations.sh and compare/run.sh, so each report's "Tree
# changed by the run" counts only what that run itself did, not files
# that were already uncommitted when it started.
#
#   tree_state ROOT [EXCLUDE ...] > FILE
#       The work tree's dirty paths, sorted, one line each: the
#       `git status --porcelain` line, a tab, and the content hash of
#       the file (git hash-object; - when it is gone). An EXCLUDE ending
#       in / leaves out everything under it; any other leaves out that
#       one path. Each run excludes the files it always writes.
#   tree_changed BEFORE AFTER
#       The paths whose line or hash differs between two listings: a
#       path that became dirty, changed status or content, or became
#       clean. One path per line.
#   tree_cell N
#       The report cell: "no", or "**yes, N path(s)**".
#
# Take the first listing before the first model runs and the second
# after the last. Written for bash 3.2.
# =====================================================================

tree_state(){ local root="$1"; shift
  ( cd "$root" 2>/dev/null || exit 0
    git status --porcelain --untracked-files=all 2>/dev/null |
    while IFS= read -r line; do
      p="${line:3}"; p="${p##* -> }"; skip=0
      for x in "$@"; do
        case "$x" in
          */) case "$p" in "$x"*) skip=1 ;; esac ;;
          *)  [ "$p" = "$x" ] && skip=1 ;;
        esac
      done
      [ "$skip" = 1 ] && continue
      if [ -f "$p" ]; then h="$(git hash-object -- "$p" 2>/dev/null)"; else h=-; fi
      printf '%s\t%s\n' "$line" "${h:--}"
    done | sort ); }

tree_changed(){
  comm -3 "$1" "$2" | sed 's/^	//' | cut -f1 | cut -c4- | sed 's/.* -> //' | sort -u; }

tree_cell(){ if [ "$1" = 0 ]; then echo no; else echo "**yes, $1 path(s)**"; fi; }
