#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Recreate the DERIVED warehouse from schema. Destructive to $DB, and
# deliberately harmless to $ARCHIVE_DB: the raw layer is the one thing
# that must survive an init, because rebuild.sh replays it back into the
# database this script just wiped.
#
# The archive schema is applied idempotently (IF NOT EXISTS), so a first
# run creates it and every later run leaves the accumulated deliveries
# exactly where they are. To discard the raw layer you must say so:
# `make clean-archive`.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

echo "==> Initialising archive $ARCHIVE_DB (raw layer, preserved)"
DB="$ARCHIVE_DB" sql_file "$ROOT_DIR/schema/05_archive.sql"
n="$(DB="$ARCHIVE_DB" sql_scalar "SELECT COUNT(*) FROM loaded_files;")"
echo "    $n delivery(ies) already archived."

echo "==> Initialising $DB (incremental-aware variant)"
rm -f "$DB"
cat "$ROOT_DIR/schema/01_metadata.sql" \
    "$ROOT_DIR/schema/02_data.sql" \
    "$ROOT_DIR/schema/03_seed_metadata.sql" \
    "$ROOT_DIR/schema/04_views.sql" | sql
echo "    schema created, model + feed strategies seeded."
