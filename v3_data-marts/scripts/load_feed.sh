#!/usr/bin/env bash
# ---------------------------------------------------------------------
# DELIVERY DRIVER -- ingest ONE delivery file into the star, safely.
#   usage: load_feed.sh <delivery.sql> <file_id>
#
# CAPTURE THE RAW INPUT, THEN APPLY IT -- the archive discipline
# shared by every sibling demo:
#   * a file_id already COMPLETE is skipped; COMPLETE is written only
#     after every loader succeeds, so a half-applied delivery stays
#     retryable rather than being skipped as done.
#   * the delivery is archived verbatim, pre-dedup, BEFORE
#     any loader runs -- a crash mid-load leaves the raw input safe.
#   * archiving is idempotent (INSERT OR IGNORE never fires the archive's
#     append-only triggers); a file_id reused with a different row
#     count is rejected, because a file_id names a delivery's CONTENT.
#   * success clears the stage; a crashed delivery leaves its staged
#     rows in place as forensics for the retry.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
FILE="${1:?usage: load_feed.sh <delivery.sql> <file_id>}"
FILE_ID="${2:?usage: load_feed.sh <delivery.sql> <file_id>}"
q_file_id="$(sql_quote "$FILE_ID")"
q_bts="$(sql_quote "$BATCH_TS")"

if [ "$(asql_scalar "SELECT COUNT(*) FROM arch.loaded_files
                     WHERE file_id='$q_file_id' AND status='COMPLETE';")" -gt 0 ]; then
  echo "==> SKIP duplicate delivery '$FILE_ID' (already COMPLETE in loaded_files)"; exit 0
fi

echo "############################################################"
echo "# DELIVERY: $FILE   id=$FILE_ID   (ts=$BATCH_TS)"
echo "############################################################"

sql_run "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1;
         DELETE FROM stg_order_l1;    DELETE FROM stg_order_line_l1;
         DELETE FROM mart_load_params;
         INSERT INTO mart_load_params(batch_ts) VALUES('$q_bts');"
sql_file "$FILE"

rc="$(sql_int "$(sql_scalar "SELECT (SELECT COUNT(*) FROM stg_customer_l1)
                                  + (SELECT COUNT(*) FROM stg_product_l1)
                                  + (SELECT COUNT(*) FROM stg_order_l1)
                                  + (SELECT COUNT(*) FROM stg_order_line_l1);")")"

prev_rc="$(asql_scalar "SELECT COALESCE(row_count,-1) FROM arch.loaded_files
                        WHERE file_id='$q_file_id';")"
if [ -n "$prev_rc" ]; then
  [ "$prev_rc" = "$rc" ] || {
    echo "FATAL: delivery '$FILE_ID' was archived with $prev_rc row(s) but this file has $rc." >&2
    echo "       A file_id identifies a delivery's CONTENT. Issue a new file_id." >&2
    exit 1; }
  echo "==> RETRY of delivery '$FILE_ID' (previously STARTED, never COMPLETE)"
else
  asql_run "INSERT INTO arch.loaded_files(file_id, load_seq, batch_ts, status, row_count)
            VALUES('$q_file_id',
                   COALESCE((SELECT MAX(load_seq) FROM arch.loaded_files),0)+1,
                   '$q_bts','STARTED',$rc);"
fi

# ---- capture raw, verbatim and pre-dedup, before anything applies ----
asql_run "
  INSERT OR IGNORE INTO arch.hist_customer(file_id, load_seq, batch_ts, seq_nbr,
      customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode)
  SELECT '$q_file_id',
         (SELECT load_seq FROM arch.loaded_files WHERE file_id='$q_file_id'),
         (SELECT batch_ts FROM arch.loaded_files WHERE file_id='$q_file_id'),
         s.rowid, s.customer_id, s.full_name, s.email_addr, s.signup_date,
         s.extract_dt, s.op, s.load_mode
  FROM stg_customer_l1 s;
  INSERT OR IGNORE INTO arch.hist_product(file_id, load_seq, batch_ts, seq_nbr,
      sku, prod_name, price, currency, extract_dt, op, load_mode)
  SELECT '$q_file_id',
         (SELECT load_seq FROM arch.loaded_files WHERE file_id='$q_file_id'),
         (SELECT batch_ts FROM arch.loaded_files WHERE file_id='$q_file_id'),
         s.rowid, s.sku, s.prod_name, s.price, s.currency,
         s.extract_dt, s.op, s.load_mode
  FROM stg_product_l1 s;
  INSERT OR IGNORE INTO arch.hist_order(file_id, load_seq, batch_ts, seq_nbr,
      order_ref, customer_ref, status, amount, currency, placed_at,
      extract_dt, op, load_mode)
  SELECT '$q_file_id',
         (SELECT load_seq FROM arch.loaded_files WHERE file_id='$q_file_id'),
         (SELECT batch_ts FROM arch.loaded_files WHERE file_id='$q_file_id'),
         s.rowid, s.order_ref, s.customer_ref, s.status, s.amount, s.currency,
         s.placed_at, s.extract_dt, s.op, s.load_mode
  FROM stg_order_l1 s;
  INSERT OR IGNORE INTO arch.hist_order_line(file_id, load_seq, batch_ts, seq_nbr,
      order_ref, sku, extract_dt, op, load_mode)
  SELECT '$q_file_id',
         (SELECT load_seq FROM arch.loaded_files WHERE file_id='$q_file_id'),
         (SELECT batch_ts FROM arch.loaded_files WHERE file_id='$q_file_id'),
         s.rowid, s.order_ref, s.sku, s.extract_dt, s.op, s.load_mode
  FROM stg_order_line_l1 s;"

arc="$(sql_int "$(asql_scalar "
  SELECT (SELECT COUNT(*) FROM arch.hist_customer   WHERE file_id='$q_file_id')
       + (SELECT COUNT(*) FROM arch.hist_product    WHERE file_id='$q_file_id')
       + (SELECT COUNT(*) FROM arch.hist_order      WHERE file_id='$q_file_id')
       + (SELECT COUNT(*) FROM arch.hist_order_line WHERE file_id='$q_file_id');")")"
[ "$arc" = "$rc" ] || {
  echo "FATAL: archived $arc row(s) but staged $rc for '$FILE_ID'." >&2; exit 1; }
echo "==> Archived $arc raw row(s) to the archive for delivery '$FILE_ID'"

# ---- now apply it -----------------------------------------------------
"$(dirname "$0")/apply_delivery.sh"

asql_run "UPDATE arch.loaded_files SET status='COMPLETE' WHERE file_id='$q_file_id';"

# Success clears the workbench; a crashed delivery aborts above (set -e)
# and leaves its staged rows as forensics for the retry.
sql_run "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1;
         DELETE FROM stg_order_l1;    DELETE FROM stg_order_line_l1;"
echo "==> Delivery complete."
