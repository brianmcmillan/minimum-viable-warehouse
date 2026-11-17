#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Shared helpers for the Kimball mart loaders. Same house rules as the
# sibling demos: every database access goes through db(); values
# interpolated into SQL are escaped with sql_quote().
#
# TWO DATABASES, exactly like the Focal demo. $DB is the star schema --
# disposable, rebuilt from scratch by rebuild.sh. $ARCHIVE_DB is the
# archive (raw layer): every delivery ever accepted, append-only,
# plus the load-control manifest. It lives OUTSIDE build/ because
# init_db.sh removes $DB and `make clean` removes build/ -- neither may
# ever touch the archive. Reach it through adb()/asql_*, which ATTACH
# it as `arch`.
# ---------------------------------------------------------------------
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"

: "${DB:=$ROOT_DIR/build/datamart.db}"          # star schema (disposable)
: "${ARCHIVE_DB:=$ROOT_DIR/archive/datamart_archive.db}"  # raw layer (durable)
: "${SQLITE:=sqlite3}"
: "${BATCH_TS:=$(date '+%Y-%m-%d %H:%M:%S')}"   # logical load timestamp

mkdir -p "$(dirname "$DB")" "$(dirname "$ARCHIVE_DB")"

# ---- the choke point --------------------------------------------------
db() {
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in -*) opts+=("$1"); shift;; *) break;; esac
  done
  "$SQLITE" ${opts[@]+"${opts[@]}"} "$DB" "$@"
}

# Same, with the archive attached as `arch`.
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

sql_quote()   { printf "%s" "$1" | sed "s/'/''/g"; }
sql_int() {
  case "$1" in
    ''|*[!0-9]*) echo "FATAL: expected an integer, got: '$1'" >&2; return 1;;
  esac
  printf '%s' "$1"
}

# Effective load mode for a staged feed (the shared safety rule reads
# this): the delivery's own load_mode. $1 = stage-1 table (trusted).
feed_mode() { sql_scalar "SELECT COALESCE(MAX(load_mode),'INCREMENTAL') FROM $1;"; }
feed_rows() { sql_scalar "SELECT COUNT(*) FROM $1;"; }
