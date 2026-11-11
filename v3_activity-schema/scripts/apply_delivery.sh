#!/usr/bin/env bash
# APPLY one delivery already sitting in the stage-1 tables. The ONE path
# shared by load_feed.sh (ingest) and rebuild.sh (replay) -- a green
# rebuild must prove the real loader.
source "$(dirname "$0")/lib.sh"

total="$(sql_scalar "SELECT (SELECT COUNT(*) FROM stg_customer_l1)
                          + (SELECT COUNT(*) FROM stg_product_l1)
                          + (SELECT COUNT(*) FROM stg_order_l1)
                          + (SELECT COUNT(*) FROM stg_order_line_l1);")"
[ "$total" -gt 0 ] || {
  echo "FATAL: apply_delivery.sh called with an empty stage" >&2; exit 1; }

"$(dirname "$0")/load_activities.sh"
