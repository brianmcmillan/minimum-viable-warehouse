#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Shared helpers for the Kimball mart loaders. Same house rules as the
# sibling demos: every database access goes through db(); values
# interpolated into SQL are escaped with sql_quote().
#
# TWO DATABASES, exactly like the Focal demo. $DB is the star schema --
# disposable, rebuilt from scratch by rebuild.sh. $PSA_DB is the
# Persistent Staging Area: every delivery ever accepted, append-only,
# plus the load-control manifest. It lives OUTSIDE build/ because
# init_db.sh removes $DB and `make clean` removes build/ -- neither may
# ever touch the PSA. Reach it through pdb()/psql_*, which ATTACH it
# as `psa`.
# ---------------------------------------------------------------------
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"

: "${DB:=$ROOT_DIR/build/datamart.db}"          # star schema (disposable)
: "${PSA_DB:=$ROOT_DIR/psa/psa_datamart.db}"    # persistent staging (durable)
: "${SQLITE:=sqlite3}"
: "${BATCH_TS:=$(date '+%Y-%m-%d %H:%M:%S')}"   # logical load timestamp

mkdir -p "$(dirname "$DB")" "$(dirname "$PSA_DB")"

# ---- the choke point --------------------------------------------------
db() {
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in -*) opts+=("$1"); shift;; *) break;; esac
  done
  "$SQLITE" ${opts[@]+"${opts[@]}"} "$DB" "$@"
}

# Same, with the PSA attached as `psa`.
pdb() {
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in -*) opts+=("$1"); shift;; *) break;; esac
  done
  "$SQLITE" -cmd "ATTACH DATABASE '$(sql_quote "$PSA_DB")' AS psa" \
            ${opts[@]+"${opts[@]}"} "$DB" "$@"
}

sql()         { db; }
sql_run()     { db "$1"; }
sql_scalar()  { db "$1"; }
sql_file()    { db < "$1"; }
sql_table()   { db -header -column "$1"; }
psql_run()    { pdb "$1"; }
psql_scalar() { pdb "$1"; }
psql_table()  { pdb -header -column "$1"; }

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
