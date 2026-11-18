#!/usr/bin/env bash
# Q9 rule change for compare/run.sh: P -> PLACED with no reload.
# Runs in a scratch copy of the model, after the shared deliveries and the
# re-point, with $SQLITE, $DB and $ARCHIVE_DB set. Prints nothing when the
# change reaches the answers in place; prints "CANNOT<TAB><reason>" when it
# cannot, and then takes the archive route (seed + rebuild) instead, so
# run.sh can record what the archive answers.
set -euo pipefail
# A newer reference row; bv_order_status_bsat decodes from the newest.
"$SQLITE" "$DB" "INSERT INTO ref_order_status(code,label,ldts,rsrc) VALUES ('P','PLACED','2027-03-01 00:00:00','OPS.RULES');"
