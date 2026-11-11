#!/usr/bin/env bash
# Recreate the STAR SCHEMA from schema files. Destructive to $DB and
# deliberately harmless to $ARCHIVE_DB -- the archive (raw layer) must
# survive an init, because rebuild.sh replays it back into the mart
# this script just wiped. Archive schema is applied idempotently
# (IF NOT EXISTS); `make clean-archive` is the only thing that removes it.
source "$(dirname "$0")/lib.sh"

echo "==> Initialising archive $ARCHIVE_DB (raw layer, preserved)"
DB="$ARCHIVE_DB" sql_file "$ROOT_DIR/schema/02_archive.sql"
n="$(DB="$ARCHIVE_DB" sql_scalar "SELECT COUNT(*) FROM loaded_files;")"
echo "    $n delivery(ies) already archived."

echo "==> Initialising $DB (Kimball star schema)"
rm -f "$DB"
cat "$ROOT_DIR/schema/01_stage.sql" \
    "$ROOT_DIR/schema/03_dimensions.sql" \
    "$ROOT_DIR/schema/04_facts.sql" | sql
echo "    stage, dimensions (incl. dim_date $(sql_scalar 'SELECT COUNT(*) FROM dim_date;') days), facts created."
