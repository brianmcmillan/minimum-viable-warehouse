#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Shared helpers for the metrics-mart loaders. Same house rules as the
# sibling demos: every database access goes through db(); interpolated
# values go through sql_quote(); identifiers read from metadata tables
# go through sql_ident(); integers through sql_int().
#
# TWO DATABASES, exactly like the Focal and Anchor demos. $DB is the
# mart -- disposable, rebuilt from scratch by rebuild.sh. $ARCHIVE_DB is
# the raw layer: every delivery ever accepted, append-only, plus the
# manifest.
#
# Every connection turns foreign keys ON. The mart's code tables are
# real constraints: an unknown order status fails the load.
#
# ATOMIC STEPS. Each loader runs its whole step through sql_tx(). The
# sqlite3 shell does not behave the same everywhere when a statement in
# a multi-statement argument fails: some builds stop, some report the
# error and carry on to the COMMIT. Both exit non-zero. So sql_tx()
# does not rely on the shell: it copies the mart file first and puts
# the copy back if the step fails. The mart is small and disposable, so
# a file copy is the cheapest guarantee that works on every build.
# ---------------------------------------------------------------------
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"

: "${DB:=$ROOT_DIR/build/metrics.db}"
: "${ARCHIVE_DB:=$ROOT_DIR/archive/metrics_archive.db}"
: "${SQLITE:=sqlite3}"
: "${BATCH_TS:=$(date '+%Y-%m-%d %H:%M:%S')}"
: "${BATCH_NO:=0}"

mkdir -p "$(dirname "$DB")" "$(dirname "$ARCHIVE_DB")"

db() {
  local -a opts=()
  while [ "$#" -gt 0 ]; do
    case "$1" in -*) opts+=("$1"); shift;; *) break;; esac
  done
  "$SQLITE" -cmd "PRAGMA foreign_keys=ON" ${opts[@]+"${opts[@]}"} "$DB" "$@"
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

# Run one multi-statement load step; on any error leave the mart
# exactly as it was before the step.
sql_tx() {
  local bak="$DB.pre-step"
  cp -p "$DB" "$bak"
  if db "$1"; then
    rm -f "$bak"
  else
    rm -f "$DB-journal" "$DB-wal" "$DB-shm"
    mv -f "$bak" "$DB"
    echo "FATAL: load step failed; the mart is back to its state before the step." >&2
    return 1
  fi
}

# SQL that creates every group named by a path, and every ancestor of it,
# that does not exist yet. $1 is a query returning one column, gp.
# Parent and level are derived from the path, so the three encodings in
# RES_GRP cannot disagree. New ids continue from the maximum in (level,
# path) order, so replay reproduces them.
#   '/ORDER/O-100' -> name 'O-100', level 2, parent '/ORDER'
ensure_groups_sql() {
  cat <<SQL
WITH RECURSIVE want(gp) AS ($1),
pre(acc, rest) AS (
  SELECT '', substr(gp, 2) || '/' FROM want WHERE gp LIKE '/%'
  UNION
  SELECT acc || '/' || substr(rest, 1, instr(rest, '/') - 1),
         substr(rest, instr(rest, '/') + 1)
  FROM pre WHERE rest <> ''),
need AS (
  SELECT DISTINCT acc AS p, length(acc) - length(replace(acc, '/', '')) AS lvl
  FROM pre WHERE acc <> '' AND acc NOT IN (SELECT group_path FROM res_grp)),
newid AS (
  SELECT p, lvl, (SELECT COALESCE(MAX(res_grp_id), 0) FROM res_grp)
                 + ROW_NUMBER() OVER (ORDER BY lvl, p) AS id
  FROM need),
anyid AS (
  SELECT group_path AS p, res_grp_id AS id FROM res_grp
  UNION ALL SELECT p, id FROM newid)
INSERT INTO res_grp(res_grp_id, res_grp_name, parent_res_grp, group_level, group_path, srcd_ts)
SELECT n.id,
       substr(n.p, length(rtrim(n.p, replace(n.p, '/', ''))) + 1),
       CASE WHEN n.lvl = 1 THEN NULL ELSE
         (SELECT a.id FROM anyid a WHERE a.p = rtrim(rtrim(n.p, replace(n.p, '/', '')), '/')) END,
       n.lvl, n.p, '$q_bts'
FROM newid n ORDER BY n.lvl, n.p;
SQL
}

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

# The landing rows of the feeds carried by the CURRENT delivery, as an
# inline view. source_landing keeps the last delivery of EVERY feed;
# the loaders must only act on the feeds that just arrived.
CUR="(SELECT l.* FROM source_landing l
       WHERE EXISTS (SELECT 1 FROM source_landing_stage s
                     WHERE s.source_system = l.source_system
                       AND s.source_entity = l.source_entity))"
