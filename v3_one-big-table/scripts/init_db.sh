#!/usr/bin/env bash
# Recreate the derived latest tables from schema; the archive -- the
# actual warehouse -- is preserved (IF NOT EXISTS, never rm'd).
source "$(dirname "$0")/lib.sh"

echo "==> Initialising archive $ARCHIVE_DB (THE warehouse, preserved)"
DB="$ARCHIVE_DB" sql_file "$ROOT_DIR/schema/02_archive.sql"
n="$(DB="$ARCHIVE_DB" sql_scalar "SELECT COUNT(*) FROM loaded_files;")"
echo "    $n delivery(ies) already archived."

echo "==> Initialising $DB (derived latest tables)"
rm -f "$DB"
sql_file "$ROOT_DIR/schema/01_stage.sql"
echo "    stage, latest tables and views created."
