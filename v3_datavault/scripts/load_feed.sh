#!/usr/bin/env bash
# ---------------------------------------------------------------------
# DELIVERY DRIVER -- ingest ONE delivery file into the vault.
#   usage: load_feed.sh <delivery.sql> <file_id>
#
#   * load control mirrors the Focal demo: a file_id already COMPLETE is
#     skipped; COMPLETE is written only after every loader succeeds, so a
#     half-applied delivery stays retryable.
#   * the delivery file INSERTs wide rows into the stage-1 tables; the
#     stage-2 views add ldts/rsrc/diff_str and dedupe by recency.
#   * there is NO separate delivery archive here. The insert-only raw
#     vault preserves every attribute state and every presence assertion
#     -- that is DV's durability story. What it does NOT preserve is the
#     delivery files themselves; see DATAVAULT.md for the comparison.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
FILE="${1:?usage: load_feed.sh <delivery.sql> <file_id>}"
FILE_ID="${2:?usage: load_feed.sh <delivery.sql> <file_id>}"
q_file_id="$(sql_quote "$FILE_ID")"
q_bts="$(sql_quote "$BATCH_TS")"

if [ "$(sql_scalar "SELECT COUNT(*) FROM dv_load_audit
                    WHERE file_id='$q_file_id' AND status='COMPLETE';")" -gt 0 ]; then
  echo "==> SKIP duplicate delivery '$FILE_ID' (already COMPLETE in dv_load_audit)"; exit 0
fi

echo "############################################################"
echo "# DELIVERY: $FILE   id=$FILE_ID   (ldts=$BATCH_TS)"
echo "############################################################"

sql_run "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1;
         DELETE FROM stg_order_l1;    DELETE FROM stg_order_line_l1;
         DELETE FROM dv_load_params;
         INSERT INTO dv_load_params(batch_ts) VALUES('$q_bts');"
sql_file "$FILE"

rc="$(sql_int "$(sql_scalar "SELECT (SELECT COUNT(*) FROM stg_customer_l1)
                                  + (SELECT COUNT(*) FROM stg_product_l1)
                                  + (SELECT COUNT(*) FROM stg_order_l1)
                                  + (SELECT COUNT(*) FROM stg_order_line_l1);")")"

if [ "$(sql_scalar "SELECT COUNT(*) FROM dv_load_audit WHERE file_id='$q_file_id';")" -gt 0 ]; then
  echo "==> RETRY of delivery '$FILE_ID' (previously STARTED, never COMPLETE)"
else
  sql_run "INSERT INTO dv_load_audit(file_id, load_seq, batch_ts, status, row_count)
           VALUES('$q_file_id',
                  COALESCE((SELECT MAX(load_seq) FROM dv_load_audit),0)+1,
                  '$q_bts','STARTED',$rc);"
fi

"$(dirname "$0")/load_hubs.sh"
"$(dirname "$0")/load_sats.sh"
"$(dirname "$0")/load_links.sh"

sql_run "UPDATE dv_load_audit SET status='COMPLETE' WHERE file_id='$q_file_id';"

# Success clears the workbench: stage is transient by definition, and a
# blank stage is the observable difference between "loaded" and "died
# mid-load". A crashed delivery aborts above (set -e) and LEAVES its
# staged rows in place -- they are the forensics for the retry.
# (dv_load_params keeps the last ldts on purpose: it is a parameter,
# not staged data.)
sql_run "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1;
         DELETE FROM stg_order_l1;    DELETE FROM stg_order_line_l1;"
echo "==> Delivery complete."
