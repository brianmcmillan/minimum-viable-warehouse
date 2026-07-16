#!/usr/bin/env bash
# Recreate the constellation from schema. Destructive to $DB, harmless
# to $ARCHIVE_DB -- rebuild.sh replays the archive back into the
# database this script just wiped. `make clean-archive` is the only
# thing that discards the raw layer.
source "$(dirname "$0")/lib.sh"

echo "==> Initialising archive $ARCHIVE_DB (raw layer, preserved)"
DB="$ARCHIVE_DB" sql_file "$ROOT_DIR/schema/02_archive.sql"
n="$(DB="$ARCHIVE_DB" sql_scalar "SELECT COUNT(*) FROM loaded_files;")"
echo "    $n delivery(ies) already archived."

echo "==> Initialising $DB (Anchor Modeling, 6NF)"
rm -f "$DB"
cat "$ROOT_DIR/schema/01_landing.sql" \
    "$ROOT_DIR/schema/03_anchor.sql" \
    "$ROOT_DIR/schema/04_views.sql" | sql
echo "    landing, $(sql_scalar "SELECT COUNT(*) FROM sqlite_master
          WHERE type='table' AND (name LIKE 'CU\_%' ESCAPE '\'
             OR name LIKE 'PR\_%' ESCAPE '\' OR name LIKE 'OD\_%' ESCAPE '\'
             OR name IN ('EST_ExistenceStatus','OST_OrderStatus','CUR_Currency'));")-table constellation, views created."
