#!/usr/bin/env bash
# ---------------------------------------------------------------------
# APPLY one delivery that is already sitting in the stage-1 tables.
#   usage: BATCH_TS=<ts> apply_delivery.sh
#
# The ONE path from staged rows to the star, shared by both callers --
# load_feed.sh (ingest) and rebuild.sh (PSA replay). They must share it:
# if replay went through its own code, a green rebuild test would prove
# only that the replay code works, not that it reproduces what ingest
# actually did. (Same structural rule as the Focal demo.)
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

total="$(sql_scalar "SELECT (SELECT COUNT(*) FROM stg_customer_l1)
                          + (SELECT COUNT(*) FROM stg_product_l1)
                          + (SELECT COUNT(*) FROM stg_order_l1)
                          + (SELECT COUNT(*) FROM stg_order_line_l1);")"
[ "$total" -gt 0 ] || {
  echo "FATAL: apply_delivery.sh called with an empty stage" >&2; exit 1; }

"$(dirname "$0")/load_dims.sh"
"$(dirname "$0")/load_facts.sh"
