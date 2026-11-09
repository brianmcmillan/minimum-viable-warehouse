#!/usr/bin/env bash
# Recreate the core + USS database from schema; the archive is preserved
# (IF NOT EXISTS, never rm'd). `make clean-archive` is the only destroyer
# of raw history.
source "$(dirname "$0")/lib.sh"

echo "==> Initialising archive $ARCHIVE_DB (raw layer, preserved)"
DB="$ARCHIVE_DB" sql_file "$ROOT_DIR/schema/02_archive.sql"
n="$(DB="$ARCHIVE_DB" sql_scalar "SELECT COUNT(*) FROM loaded_files;")"
echo "    $n delivery(ies) already archived."

echo "==> Initialising $DB (insert-only core + Unified Star Schema)"
rm -f "$DB"
cat "$ROOT_DIR/schema/01_stage.sql" \
    "$ROOT_DIR/schema/03_core.sql" \
    "$ROOT_DIR/schema/04_uss.sql" | sql
echo "    stage, core, USS tables, bridge and views created."
