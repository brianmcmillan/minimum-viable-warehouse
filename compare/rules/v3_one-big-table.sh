#!/usr/bin/env bash
# Q9 rule change for compare/run.sh: P -> PLACED with no reload.
# Runs in a scratch copy of the model, after the shared deliveries and the
# re-point, with $SQLITE, $DB and $ARCHIVE_DB set. Prints nothing when the
# change reaches the answers in place; prints "CANNOT<TAB><reason>" when it
# cannot, and then takes the archive route (seed + rebuild) instead, so
# run.sh can record what the archive answers.
set -euo pipefail
# The rule lives in v_order's CASE: every consumer owns its own copy.
view_sql="$("$SQLITE" "$DB" "SELECT sql FROM sqlite_master WHERE type='view' AND name='v_order'")"
"$SQLITE" "$DB" "DROP VIEW v_order; $(printf '%s' "$view_sql" | sed "s/'PENDING'/'PLACED'/");"
