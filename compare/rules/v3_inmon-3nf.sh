#!/usr/bin/env bash
# Q9 rule change for compare/run.sh: P -> PLACED with no reload.
# Runs in a scratch copy of the model, after the shared deliveries and the
# re-point, with $SQLITE, $DB and $ARCHIVE_DB set. Prints nothing when the
# change reaches the answers in place; prints "CANNOT<TAB><reason>" when it
# cannot, and then takes the archive route (seed + rebuild) instead, so
# run.sh can record what the archive answers.
set -euo pipefail
printf 'CANNOT\tconformed at ingest: stored rows keep PENDING until a rebuild\n'
sed -i.bak "s/('P','PENDING')/('P','PLACED')/" schema/03_edw.sql
./scripts/rebuild.sh >/dev/null 2>&1
