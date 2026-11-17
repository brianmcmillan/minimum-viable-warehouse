#!/usr/bin/env bash
# ---------------------------------------------------------------------
# REBUILD the star schema from the archive (raw layer).
#
# Drops $DB entirely and replays every archived delivery back through
# the same code path that ingested it (apply_delivery.sh). Dimensions,
# SCD2 version chains, surrogate keys and facts are all regenerated --
# and the surrogate keys come back IDENTICAL, because:
#
#   * deliveries replay in load_seq order (ingest order), and
#   * each delivery's rows are restored to stage in seq_nbr order (the
#     recency-dedup tiebreak reads the staged rowid), and
#   * every dim INSERT carries ORDER BY <business key>.
#
# This is Kimball's answer to "the mart is disposable": fix an ETL bug
# or restructure a decode dimension, then rebuild from the archive. Only
# true while the archive is complete -- prune one delivery and version
# chains and keys start moving. (Same argument, same proof, as the
# Focal archive.)
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

n_deliv="$(sql_int "$(asql_scalar "SELECT COUNT(*) FROM arch.loaded_files;")")"
[ "$n_deliv" -gt 0 ] || {
  echo "FATAL: archive $ARCHIVE_DB holds no deliveries -- nothing to rebuild from." >&2
  exit 1; }

echo "======================================================================"
echo "  REBUILD from $ARCHIVE_DB  ($n_deliv delivery(ies))"
echo "======================================================================"

"$(dirname "$0")/init_db.sh"

asql_run "SELECT file_id||'|'||batch_ts FROM arch.loaded_files ORDER BY load_seq;" |
while IFS='|' read -r fid bts; do
  q_fid="$(sql_quote "$fid")"
  echo "############################################################"
  echo "# REPLAY: id=$fid   (ts=$bts)"
  echo "############################################################"
  adb "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1;
       DELETE FROM stg_order_l1;    DELETE FROM stg_order_line_l1;
       DELETE FROM mart_load_params;
       INSERT INTO mart_load_params(batch_ts) VALUES('$(sql_quote "$bts")');
       INSERT INTO stg_customer_l1(customer_id,full_name,email_addr,signup_date,extract_dt,op,load_mode)
         SELECT customer_id,full_name,email_addr,signup_date,extract_dt,op,load_mode
         FROM arch.hist_customer WHERE file_id='$q_fid' ORDER BY seq_nbr;
       INSERT INTO stg_product_l1(sku,prod_name,price,currency,extract_dt,op,load_mode)
         SELECT sku,prod_name,price,currency,extract_dt,op,load_mode
         FROM arch.hist_product WHERE file_id='$q_fid' ORDER BY seq_nbr;
       INSERT INTO stg_order_l1(order_ref,customer_ref,status,amount,currency,placed_at,extract_dt,op,load_mode)
         SELECT order_ref,customer_ref,status,amount,currency,placed_at,extract_dt,op,load_mode
         FROM arch.hist_order WHERE file_id='$q_fid' ORDER BY seq_nbr;
       INSERT INTO stg_order_line_l1(order_ref,sku,extract_dt,op,load_mode)
         SELECT order_ref,sku,extract_dt,op,load_mode
         FROM arch.hist_order_line WHERE file_id='$q_fid' ORDER BY seq_nbr;"
  BATCH_TS="$bts" "$(dirname "$0")/apply_delivery.sh"
done

# Leave the stage as a successful ingest would: blank.
sql_run "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1;
         DELETE FROM stg_order_l1;    DELETE FROM stg_order_line_l1;"
echo "==> Rebuild complete: $n_deliv delivery(ies) replayed."
