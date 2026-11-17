#!/usr/bin/env bash
# ---------------------------------------------------------------------
# DELIVERY DRIVER -- ingest ONE delivery file, safely.
#   usage: load_feed.sh <delivery.sql> <file_id>
#
# CAPTURE THE RAW INPUT, THEN APPLY IT. In that order, always. A delivery
# that crashes half-way through the loaders is still archived, so the
# retry replays byte-identical input instead of whatever the extractor
# happens to be emitting by then. This is the property that makes the
# derived warehouse disposable.
#
# Deliveries arrive WIDE, like every other model's: the file INSERTs one
# row per record into the stg_*_l1 tables. The order is
#   stage wide -> load control -> archive (wide, verbatim) ->
#   stage_narrow.sh (unpivot to key/value rows) -> loaders -> COMPLETE.
# Load control and the archive block are the shared ones, byte-for-byte
# the same as in the other nine models.
#
#   * a file_id names a delivery's CONTENT. A re-sent id is compared with
#     what the archive holds; any difference is rejected, and only an
#     identical COMPLETE delivery is skipped.
#   * the delivery is only marked COMPLETE after every loader succeeds;
#     a half-applied delivery stays retryable rather than being skipped
#     as "done".
#   * archiving is idempotent: INSERT OR IGNORE, which (unlike OR REPLACE)
#     does not fire the archive's append-only delete trigger.
#   * success leaves both stages holding this delivery (the loaders' scope
#     and the tests read them); the next delivery clears them.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
FILE="${1:?usage: load_feed.sh <delivery.sql> <file_id>}"
FILE_ID="${2:?usage: load_feed.sh <delivery.sql> <file_id>}"
q_file_id="$(sql_quote "$FILE_ID")"
q_bts="$(sql_quote "$BATCH_TS")"

echo "############################################################"
echo "# DELIVERY: $FILE   id=$FILE_ID   (ts=$BATCH_TS)"
echo "############################################################"

# Stage BEFORE deciding whether to skip. A file_id names a delivery's
# CONTENT, so the only way to know a re-sent file really is the same
# delivery is to look at it. Both stages are cleared here, so a skip or a
# rejection below leaves no previous delivery's rows behind.
sql_run "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1;
         DELETE FROM stg_order_l1;    DELETE FROM stg_order_line_l1;
         DELETE FROM source_landing_stage;"
sql_file "$FILE"

rc="$(sql_int "$(sql_scalar "SELECT (SELECT COUNT(*) FROM stg_customer_l1)
                                  + (SELECT COUNT(*) FROM stg_product_l1)
                                  + (SELECT COUNT(*) FROM stg_order_l1)
                                  + (SELECT COUNT(*) FROM stg_order_line_l1);")")"

# Load control, the same rule in all ten models. The file is staged
# BEFORE deciding to skip: a file_id names a delivery's CONTENT, and the
# only way to know a re-sent file is the same delivery is to compare it
# with what was archived.
#   * the row count must match the manifest, always;
#   * once rows are archived, every row must match exactly, both ways,
#     seq_nbr included -- row order is the recency tiebreak, so the same
#     rows in a different order are a different delivery;
#   * only then does a COMPLETE id skip and a STARTED id retry.
# Without the content check, a crashed delivery retried with different
# values would load rows the archive does not hold, and `make rebuild`
# would quietly produce a different warehouse.
prev_status="$(asql_scalar "SELECT status FROM arch.loaded_files WHERE file_id='$q_file_id';")"
if [ -n "$prev_status" ]; then
  prev_rc="$(asql_scalar "SELECT COALESCE(row_count,-1) FROM arch.loaded_files
                          WHERE file_id='$q_file_id';")"
  [ "$prev_rc" = "$rc" ] || {
    echo "FATAL: delivery '$FILE_ID' was archived with $prev_rc row(s) but this file has $rc." >&2
    echo "       A file_id identifies a delivery's CONTENT. Issue a new file_id." >&2
    exit 1; }
  if [ "$(asql_scalar "SELECT (SELECT COUNT(*) FROM arch.hist_customer WHERE file_id='$q_file_id')
         + (SELECT COUNT(*) FROM arch.hist_product WHERE file_id='$q_file_id')
         + (SELECT COUNT(*) FROM arch.hist_order WHERE file_id='$q_file_id')
         + (SELECT COUNT(*) FROM arch.hist_order_line WHERE file_id='$q_file_id');")" -gt 0 ]; then
    drift="$(sql_int "$(asql_scalar "
      SELECT (SELECT COUNT(*) FROM (SELECT rowid, customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode FROM stg_customer_l1
                                  EXCEPT SELECT seq_nbr, customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode FROM arch.hist_customer WHERE file_id='$q_file_id'))
         + (SELECT COUNT(*) FROM (SELECT seq_nbr, customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode FROM arch.hist_customer WHERE file_id='$q_file_id'
                                  EXCEPT SELECT rowid, customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode FROM stg_customer_l1))
         + (SELECT COUNT(*) FROM (SELECT rowid, sku, prod_name, price, currency, extract_dt, op, load_mode FROM stg_product_l1
                                  EXCEPT SELECT seq_nbr, sku, prod_name, price, currency, extract_dt, op, load_mode FROM arch.hist_product WHERE file_id='$q_file_id'))
         + (SELECT COUNT(*) FROM (SELECT seq_nbr, sku, prod_name, price, currency, extract_dt, op, load_mode FROM arch.hist_product WHERE file_id='$q_file_id'
                                  EXCEPT SELECT rowid, sku, prod_name, price, currency, extract_dt, op, load_mode FROM stg_product_l1))
         + (SELECT COUNT(*) FROM (SELECT rowid, order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode FROM stg_order_l1
                                  EXCEPT SELECT seq_nbr, order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode FROM arch.hist_order WHERE file_id='$q_file_id'))
         + (SELECT COUNT(*) FROM (SELECT seq_nbr, order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode FROM arch.hist_order WHERE file_id='$q_file_id'
                                  EXCEPT SELECT rowid, order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode FROM stg_order_l1))
         + (SELECT COUNT(*) FROM (SELECT rowid, order_ref, sku, extract_dt, op, load_mode FROM stg_order_line_l1
                                  EXCEPT SELECT seq_nbr, order_ref, sku, extract_dt, op, load_mode FROM arch.hist_order_line WHERE file_id='$q_file_id'))
         + (SELECT COUNT(*) FROM (SELECT seq_nbr, order_ref, sku, extract_dt, op, load_mode FROM arch.hist_order_line WHERE file_id='$q_file_id'
                                  EXCEPT SELECT rowid, order_ref, sku, extract_dt, op, load_mode FROM stg_order_line_l1));")")"
    [ "$drift" -eq 0 ] || {
      echo "FATAL: '$FILE' differs from the delivery already archived as '$FILE_ID'" >&2
      echo "       ($drift row(s) differ). A file_id identifies CONTENT; issue a new one." >&2
      exit 1; }
  fi
  if [ "$prev_status" = "COMPLETE" ]; then
    sql_run "DELETE FROM stg_customer_l1; DELETE FROM stg_product_l1;
             DELETE FROM stg_order_l1;    DELETE FROM stg_order_line_l1;"
    echo "==> SKIP duplicate delivery '$FILE_ID' (already COMPLETE in loaded_files)"; exit 0
  fi
  echo "==> RETRY of delivery '$FILE_ID' (previously STARTED, never COMPLETE)"
else
  asql_run "INSERT INTO arch.loaded_files(file_id, load_seq, batch_ts, status, row_count)
            VALUES('$q_file_id',
                   COALESCE((SELECT MAX(load_seq) FROM arch.loaded_files),0)+1,
                   '$q_bts','STARTED',$rc);"
fi

# ---- capture the raw delivery, verbatim and pre-dedup ----------------
# seq_nbr is the wide stage rowid: replay restores each stg_*_l1 table in
# this order because the dedup tiebreak reads it (via stage_narrow.sh).
# load_seq/batch_ts are denormalised so the archive can replay without
# consulting focal.db at all.
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
echo "==> Archived $arc raw row(s) for delivery '$FILE_ID'"

# ---- derive the narrow rows, then apply ------------------------------
"$(dirname "$0")/stage_narrow.sh"
"$(dirname "$0")/apply_delivery.sh"

# Mark COMPLETE only after every loader has succeeded. If one crashes,
# set -e aborts before this update, so the delivery stays STARTED and the
# retry re-applies it instead of skipping it forever.
asql_run "UPDATE arch.loaded_files SET status='COMPLETE' WHERE file_id='$q_file_id';"
echo "==> Delivery complete."
