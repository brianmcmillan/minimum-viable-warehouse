#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Shared helpers for the Data Vault loaders. Pure bash + the sqlite3
# CLI, same house rules as the Focal demo's lib.sh:
#
#   * EVERY database access goes through db(). No script invokes
#     "$SQLITE" directly -- connection-wide concerns live in one place.
#   * values interpolated into SQL are escaped with sql_quote();
#     no interpolation site is left raw.
# ---------------------------------------------------------------------
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"

: "${DB:=$ROOT_DIR/build/datavault.db}"        # the vault database
: "${SQLITE:=sqlite3}"                          # sqlite3 binary (override in tests)
: "${BATCH_TS:=$(date '+%Y-%m-%d %H:%M:%S')}"   # logical load timestamp (= ldts)

mkdir -p "$(dirname "$DB")"

# ---- the choke point --------------------------------------------------
db() {
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in -*) opts+=("$1"); shift;; *) break;; esac
  done
  "$SQLITE" ${opts[@]+"${opts[@]}"} "$DB" "$@"
}

sql()        { db; }                      # multi-statement SQL from stdin
sql_run()    { db "$1"; }                 # one SQL string, list output
sql_scalar() { db "$1"; }                 # one SQL string, single value
sql_file()   { db < "$1"; }               # run a .sql file
sql_table()  { db -header -column "$1"; } # human-readable (reporting only)

# Escape a value for embedding inside a single-quoted SQL literal.
sql_quote()  { printf "%s" "$1" | sed "s/'/''/g"; }

# Validate an integer interpolated unquoted.
sql_int() {
  case "$1" in
    ''|*[!0-9]*) echo "FATAL: expected an integer, got: '$1'" >&2; return 1;;
  esac
  printf '%s' "$1"
}

# Effective load mode for a staged feed: the delivery's own load_mode.
# Same central rule as the Focal demo: ABSENCE means DELETE only if this
# returns FULL. $1 = stage-1 table name (trusted, from our own scripts).
feed_mode() { sql_scalar "SELECT COALESCE(MAX(load_mode),'INCREMENTAL') FROM $1;"; }

# Row count of a stage-1 table.
feed_rows() { sql_scalar "SELECT COUNT(*) FROM $1;"; }
