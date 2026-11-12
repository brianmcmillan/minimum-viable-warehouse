#!/usr/bin/env bash
# Recreate the mart from schema. Destructive to $DB, harmless to
# $ARCHIVE_DB -- rebuild.sh replays the archive back into the database
# this script just wiped. `make clean-archive` is the only thing that
# discards the raw layer.
source "$(dirname "$0")/lib.sh"

echo "==> Initialising archive $ARCHIVE_DB (raw layer, preserved)"
DB="$ARCHIVE_DB" sql_file "$ROOT_DIR/schema/02_archive.sql"
n="$(DB="$ARCHIVE_DB" sql_scalar "SELECT COUNT(*) FROM loaded_files;")"
echo "    $n delivery(ies) already archived."

echo "==> Initialising $DB (metrics mart, 3NF)"
rm -f "$DB"
cat "$ROOT_DIR/schema/01_landing.sql" \
    "$ROOT_DIR/schema/03_mart.sql" \
    "$ROOT_DIR/schema/04_seed.sql" \
    "$ROOT_DIR/schema/05_views.sql" | sql
echo "    landing, staging, $(sql_scalar "SELECT COUNT(*) FROM sqlite_master
          WHERE type='table' AND name NOT LIKE 'source\_%' ESCAPE '\'
            AND name NOT LIKE 'meta\_%' ESCAPE '\' AND name NOT LIKE '%\_stg%' ESCAPE '\'
            AND name <> 'load_guard';") core tables, views created."
