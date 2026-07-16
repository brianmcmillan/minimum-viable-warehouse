#!/usr/bin/env bash
# REBUILD = init + ONE full refresh. No replay loop, because there is no
# incremental state to reconstruct -- the latest tables are a pure
# function of the archive. This is the rhetorical payoff of the pattern:
# rebuild is trivial precisely because nothing was ever derived
# incrementally. (The cost lives elsewhere: in refresh_latest.sh, paid
# on every load, and in every history question -- see OBT.md.)
source "$(dirname "$0")/lib.sh"

n_deliv="$(sql_int "$(asql_scalar "SELECT COUNT(*) FROM arch.loaded_files;")")"
[ "$n_deliv" -gt 0 ] || {
  echo "FATAL: archive $ARCHIVE_DB holds no deliveries -- nothing to rebuild from." >&2
  exit 1; }

echo "======================================================================"
echo "  REBUILD from $ARCHIVE_DB  ($n_deliv delivery(ies), one refresh)"
echo "======================================================================"
"$(dirname "$0")/init_db.sh"
"$(dirname "$0")/refresh_latest.sh"
echo "==> Rebuild complete."
