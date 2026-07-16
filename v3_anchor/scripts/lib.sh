#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Shared helpers for the Anchor loaders. Same house rules as the sibling
# demos: every database access goes through db(); interpolated values go
# through sql_quote(); identifiers read from metadata tables go through
# sql_ident(); integers through sql_int().
#
# TWO DATABASES, exactly like the Focal demo. $DB is the constellation --
# disposable, rebuilt from scratch by rebuild.sh. $ARCHIVE_DB is the raw
# layer: every delivery ever accepted, append-only, plus the manifest.
# ---------------------------------------------------------------------
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"

: "${DB:=$ROOT_DIR/build/anchor.db}"
: "${ARCHIVE_DB:=$ROOT_DIR/archive/anchor_archive.db}"
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
sql_ident() {
  case "$1" in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
      echo "FATAL: refusing unsafe SQL identifier: '$1'" >&2; return 1;;
  esac
  printf '%s' "$1"
}
sql_int() {
  case "$1" in
    ''|*[!0-9]*) echo "FATAL: expected an integer, got: '$1'" >&2; return 1;;
  esac
  printf '%s' "$1"
}

# Effective load mode for a feed in the CURRENT delivery (read from the
# stage: the shared rule -- absence deletes only when this says FULL).
feed_mode() { sql_scalar "SELECT COALESCE(MAX(load_mode),'INCREMENTAL')
              FROM source_landing_stage
              WHERE source_system='$(sql_quote "$1")'
                AND source_entity='$(sql_quote "$2")';"; }
# Is this feed present in the current delivery?
feed_present() { sql_scalar "SELECT COUNT(*) FROM source_landing_stage
                 WHERE source_system='$(sql_quote "$1")'
                   AND source_entity='$(sql_quote "$2")';"; }
