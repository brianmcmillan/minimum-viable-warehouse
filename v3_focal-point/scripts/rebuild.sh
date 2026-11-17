#!/usr/bin/env bash
# ---------------------------------------------------------------------
# REBUILD the derived warehouse from the raw layer.
#   usage: rebuild.sh
#
# Drops $DB entirely and replays every archived delivery back through the
# same code path that ingested it (apply_delivery.sh). Nothing is carried
# over: identifiers, surrogate keys, descriptors, relationships and
# lineage are all regenerated.
#
# Surrogate keys come back IDENTICAL, and that is not luck. Keys are
# allocated MAX(key)+ROW_NUMBER() OVER (ORDER BY idfr), so replaying the
# same deliveries in the same order against the same prior state yields
# the same assignment. Two ordering guarantees hold it up:
#
#   * deliveries replay in load_seq order -- ingest order. Replay D4 before
#     D0 and C003 becomes key 1001 instead of 1003.
#   * a delivery's wide rows are restored to the stg_*_l1 tables in
#     seq_nbr order, and stage_narrow.sh keeps that order within every
#     (key, attribute), because the recency-dedup tiebreak in
#     apply_delivery.sh reads the staged rowid.
#
# Replay runs the same two steps as ingest: stage_narrow.sh, then
# apply_delivery.sh. The archive is wide; no narrow row is ever stored.
#
# This is what "the derived warehouse is disposable" actually means, and
# it is only true while the archive is COMPLETE. Prune one delivery and
# keys start moving. See INCREMENTAL.md.
#
# Use it after fixing a loader bug, or after changing a business rule in
# meta_value_map: the raw source values were never overwritten, so the
# rule is re-derived from scratch.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

n_deliv="$(sql_int "$(asql_scalar "SELECT COUNT(*) FROM arch.loaded_files;")")"
[ "$n_deliv" -gt 0 ] || {
  echo "FATAL: archive $ARCHIVE_DB holds no deliveries -- nothing to rebuild from." >&2
  exit 1; }

n_rows="$(asql_scalar "SELECT (SELECT COUNT(*) FROM arch.hist_customer) + (SELECT COUNT(*) FROM arch.hist_product)
                           + (SELECT COUNT(*) FROM arch.hist_order)    + (SELECT COUNT(*) FROM arch.hist_order_line);")"
echo "======================================================================"
echo "  REBUILD from $ARCHIVE_DB"
echo "  $n_deliv delivery(ies), $n_rows archived raw row(s)"
echo "======================================================================"

"$(dirname "$0")/init_db.sh"

# Replay in ingest order -- the guarantee the whole rebuild rests on.
# batch_ts contains spaces but never a '|', so the project's usual
# pipe-joined read is safe here.
asql_run "SELECT file_id||'|'||batch_ts FROM arch.loaded_files ORDER BY load_seq;" |
while IFS='|' read -r fid bts; do
  q_fid="$(sql_quote "$fid")"
  echo "############################################################"
  echo "# REPLAY: id=$fid   (ts=$bts)"
  echo "############################################################"

  # Restore the delivery exactly as it was staged: same rows, same order.
  # The ORDER BY assigns stage rowids 1..N in seq_nbr order (SQLite honours
  # ORDER BY for rowid assignment in INSERT..SELECT), which the dedup
  # tiebreak depends on.
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
  BATCH_TS="$bts" "$(dirname "$0")/apply_delivery.sh"
done

echo "==> Rebuild complete: $n_deliv delivery(ies) replayed."
