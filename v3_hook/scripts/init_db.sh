#!/usr/bin/env bash
# Recreate the frame database from schema; the archive is preserved (IF NOT
# EXISTS, never rm'd). `make clean-archive` is the only destroyer of raw history.
source "$(dirname "$0")/lib.sh"

echo "==> Initialising archive $ARCHIVE_DB (raw layer, preserved)"
DB="$ARCHIVE_DB" sql_file "$ROOT_DIR/schema/02_archive.sql"
n="$(DB="$ARCHIVE_DB" sql_scalar "SELECT COUNT(*) FROM loaded_files;")"
echo "    $n delivery(ies) already archived."

echo "==> Initialising $DB (HOOK: frames + hook registry)"
rm -f "$DB"
cat "$ROOT_DIR/schema/01_stage.sql" \
    "$ROOT_DIR/schema/03_hook.sql" \
    "$ROOT_DIR/schema/04_views.sql" | sql
echo "    stage, hook registry, frames and views created."
