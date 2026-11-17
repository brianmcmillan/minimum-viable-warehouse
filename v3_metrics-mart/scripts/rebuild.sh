#!/usr/bin/env bash
# ---------------------------------------------------------------------
# REBUILD the mart from the raw layer: init + ordered replay through
# stage_narrow.sh and apply_delivery.sh, the same two steps as ingest.
# Every surrogate (res_id, provider_id, res_grp_id)
# and every srcd_ts comes back identical because the archive is complete
# and three orderings hold -- load_seq across deliveries, seq_nbr within
# one (the wide stage is restored in that order and stage_narrow.sh keeps
# it within every key and attribute), ORDER BY business key inside the
# inserts.
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

# Only COMPLETE deliveries are replayed: a delivery that never finished
# was never part of the mart.
asql_run "SELECT file_id||'|'||batch_ts||'|'||load_seq FROM arch.loaded_files
          WHERE status='COMPLETE' ORDER BY load_seq;" |
while IFS='|' read -r fid bts seq; do
  q_fid="$(sql_quote "$fid")"
  echo "############################################################"
  echo "# REPLAY: id=$fid   (ts=$bts)"
  echo "############################################################"
  adb "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1;
       DELETE FROM stg_order_l1;    DELETE FROM stg_order_line_l1;
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
  "$(dirname "$0")/stage_narrow.sh"
  BATCH_TS="$bts" BATCH_NO="$seq" "$(dirname "$0")/apply_delivery.sh"
done

sql_run "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1;
         DELETE FROM stg_order_l1;    DELETE FROM stg_order_line_l1;
         DELETE FROM source_landing_stage;"
echo "==> Rebuild complete: $n_deliv delivery(ies) in the archive."
