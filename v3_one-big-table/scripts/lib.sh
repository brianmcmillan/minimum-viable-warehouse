#!/usr/bin/env bash
# Shared helpers, same house rules as every sibling demo. Two databases:
# $DB holds the recomputed latest tables (fully disposable -- rebuilt by
# ONE full refresh, no replay loop); $ARCHIVE_DB is the warehouse proper.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"

: "${DB:=$ROOT_DIR/build/obt.db}"
: "${ARCHIVE_DB:=$ROOT_DIR/archive/obt_archive.db}"
: "${SQLITE:=sqlite3}"
: "${BATCH_TS:=$(date '+%Y-%m-%d %H:%M:%S')}"

mkdir -p "$(dirname "$DB")" "$(dirname "$ARCHIVE_DB")"

db() {
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in -*) opts+=("$1"); shift;; *) break;; esac
  done
  "$SQLITE" ${opts[@]+"${opts[@]}"} "$DB" "$@"
}
adb() {
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in -*) opts+=("$1"); shift;; *) break;; esac
  done
  "$SQLITE" -cmd "ATTACH DATABASE '$(sql_quote "$ARCHIVE_DB")' AS arch" \
            ${opts[@]+"${opts[@]}"} "$DB" "$@"
}

sql()         { db; }
sql_run()     { db "$1"; }
sql_scalar()  { db "$1"; }
sql_file()    { db < "$1"; }
sql_table()   { db -header -column "$1"; }
asql_run()    { adb "$1"; }
asql_scalar() { adb "$1"; }
asql_table()  { adb -header -column "$1"; }

sql_quote()  { printf "%s" "$1" | sed "s/'/''/g"; }
sql_int() {
  case "$1" in
    ''|*[!0-9]*) echo "FATAL: expected an integer, got: '$1'" >&2; return 1;;
  esac
  printf '%s' "$1"
}
