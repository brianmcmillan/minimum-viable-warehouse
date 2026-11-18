#!/usr/bin/env bash
# Q9 rule change for compare/run.sh: P -> PLACED with no reload.
# Runs in a scratch copy of the model, after the shared deliveries and the
# re-point, with $SQLITE, $DB and $ARCHIVE_DB set. Prints nothing when the
# change reaches the answers in place; prints "CANNOT<TAB><reason>" when it
# cannot, and then takes the archive route (seed + rebuild) instead, so
# run.sh can record what the archive answers.
set -euo pipefail
"$SQLITE" "$DB" "UPDATE ref_oms_order_status SET status_name='PLACED' WHERE status_code='P';"
