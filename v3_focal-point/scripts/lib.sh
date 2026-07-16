#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Shared helpers for the Focal loader. Pure bash + the sqlite3 CLI.
# No Python, no external deps. Works with macOS's built-in sqlite3.
#
# EVERY database access in this project goes through db() below. No other
# script may invoke "$SQLITE" directly. Connection-wide concerns -- WAL
# and busy_timeout pragmas, transaction scoping, and eventually a single
# long-lived connection -- need exactly one place to live, and this is it.
#
# Values interpolated into SQL are escaped with sql_quote(). Identifiers
# (table/column names, read from the metadata tables) cannot be escaped
# that way, so they are validated with sql_ident(); integers likewise with
# sql_int(). Between the three, no interpolation site is left raw.
#
# TWO DATABASES. $DB is the derived warehouse -- disposable, rebuilt from
# scratch by rebuild.sh. $ARCHIVE_DB is the raw layer: every delivery ever
# accepted, append-only, plus the load-control manifest. It lives OUTSIDE
# build/ because init_db.sh removes $DB and `make clean` removes build/ --
# neither may ever touch the archive. Reach it through adb()/asql_*, which
# ATTACH it as `arch`.
# ---------------------------------------------------------------------
set -euo pipefail

# Resolve project root (this file lives in <root>/scripts)
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"

: "${DB:=$ROOT_DIR/build/focal.db}"            # derived warehouse (disposable)
: "${ARCHIVE_DB:=$ROOT_DIR/archive/focal_archive.db}"  # raw layer (durable)
: "${SQLITE:=sqlite3}"                         # sqlite3 binary (override in tests)
: "${BATCH_TS:=$(date '+%Y-%m-%d %H:%M:%S')}"  # logical load timestamp (deterministic in tests)

mkdir -p "$(dirname "$DB")" "$(dirname "$ARCHIVE_DB")"

# ---- the choke point -------------------------------------------------
# Leading arguments starting with '-' are sqlite3 CLI flags (they must
# precede the database file); any remaining argument is the SQL string.
# With no SQL string, statements are read from stdin.
db() {
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in -*) opts+=("$1"); shift;; *) break;; esac
  done
  "$SQLITE" ${opts[@]+"${opts[@]}"} "$DB" "$@"
}

# Same, with the raw layer attached as `arch`. -cmd runs before the SQL
# argument, so `arch.` is resolvable everywhere in it. ATTACH creates the
# file if absent, which is why init_db.sh seeds its schema explicitly.
adb() {
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in -*) opts+=("$1"); shift;; *) break;; esac
  done
  "$SQLITE" -cmd "ATTACH DATABASE '$(sql_quote "$ARCHIVE_DB")' AS arch" \
            ${opts[@]+"${opts[@]}"} "$DB" "$@"
}

# ---- the ways to talk to the database --------------------------------
sql()        { db; }                      # multi-statement SQL from stdin
sql_run()    { db "$1"; }                 # one SQL string, list output (0..n rows)
sql_scalar() { db "$1"; }                 # one SQL string, single value by convention
sql_file()   { db < "$1"; }               # run a .sql file
sql_table()  { db -header -column "$1"; } # human-readable output (reporting only)

# ---- the same, with the archive attached as `arch` --------------------
asql()        { adb; }
asql_run()    { adb "$1"; }
asql_scalar() { adb "$1"; }
asql_table()  { adb -header -column "$1"; }

# ---- interpolation safety --------------------------------------------
# Escape a value for embedding inside a single-quoted SQL literal.
sql_quote()  { printf "%s" "$1" | sed "s/'/''/g"; }

# Validate an identifier (table or column name). These arrive from the
# metadata tables and are interpolated into SQL text, where quoting a
# literal cannot help. Anything outside [A-Za-z_][A-Za-z0-9_]* is a
# corrupt metadata row, not a table we should be writing to.
sql_ident() {
  case "$1" in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
      echo "FATAL: refusing unsafe SQL identifier: '$1'" >&2; return 1;;
  esac
  printf '%s' "$1"
}

# Validate a value interpolated into SQL unquoted (type_key, inst_key).
sql_int() {
  case "$1" in
    ''|*[!0-9]*) echo "FATAL: expected an integer, got: '$1'" >&2; return 1;;
  esac
  printf '%s' "$1"
}

# Register a pipeline execution in meta_procinst and echo its inst_key.
# Stores the exact generated SQL so row-level lineage is queryable.
log_procinst() {
  local pipeline="$1" sqlfile="$2" esc
  esc="$(sql_quote "$(cat "$sqlfile")")"
  sql_run "INSERT INTO meta_procinst(pipeline,batch_ts,sql_text)
                   VALUES('$(sql_quote "$pipeline")','$(sql_quote "$BATCH_TS")','$esc');
                   SELECT last_insert_rowid();"
}
