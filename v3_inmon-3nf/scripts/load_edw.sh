#!/usr/bin/env bash
# ---------------------------------------------------------------------
# EDW LOADER -- time-variant merge into the 3NF core, mode-aware.
#
# Per entity, the classic three steps (cf. the Kimball dims -- same
# mechanics on natural-key tables, no surrogate machinery at all):
#   1. CLOSE (UPDATE valid_to, is_current=0) the current row of every
#      version-worthy key: changed upsert, resurrection, tombstone
#      (always), FULL absence (only under FULL).
#   2. INSERT new current versions for upserted keys now lacking one.
#      A NOCHANGE key kept its row in step 1 and inserts nothing.
#   3. INSERT is_deleted marker versions carrying last-known attributes.
#
# CONFORMANCE AT INGEST: orders.status stores the value order_status_ref
# maps the raw code to. An unmapped code stores 'UNKNOWN(<code>)' --
# classic EDW cleansing flags, it does not reject. The raw code survives
# only in the archive.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Loading EDW (time-variant merge, batch_ts=$BATCH_TS)"
q_bts="$(sql_quote "$BATCH_TS")"

# ---- customer ----------------------------------------------------------
if [ "$(feed_rows stg_customer_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_customer_l1)"
  ABS=""
  [ "$mode" = "FULL" ] && ABS="OR (c.is_deleted=0 AND c.customer_ref NOT IN
        (SELECT customer_bk FROM v_stg_customer_l2))"
  sql_run "
    UPDATE customer SET valid_to='$q_bts', is_current=0
    WHERE is_current=1 AND customer_ref IN (
      SELECT c.customer_ref FROM customer c
      LEFT JOIN v_stg_customer_l2 s ON s.customer_bk = c.customer_ref
      WHERE c.is_current=1 AND (
            (s.op='UPSERT' AND (s.diff_str <> c.diff_str OR c.is_deleted=1))
         OR (s.op='DELETE' AND c.is_deleted=0)
         $ABS ));
    INSERT INTO customer(customer_ref, full_name, email, signup_date,
                         diff_str, valid_from)
    SELECT s.customer_bk, s.full_name, s.email_addr, s.signup_date,
           s.diff_str, s.ldts
    FROM v_stg_customer_l2 s
    WHERE s.op='UPSERT'
      AND NOT EXISTS (SELECT 1 FROM customer c
                      WHERE c.customer_ref=s.customer_bk AND c.is_current=1);
    INSERT INTO customer(customer_ref, full_name, email, signup_date,
                         diff_str, valid_from, is_deleted)
    SELECT c.customer_ref, c.full_name, c.email, c.signup_date,
           c.diff_str, '$q_bts', 1
    FROM customer c
    WHERE c.valid_to='$q_bts' AND c.is_deleted=0
      AND c.customer_ref NOT IN (SELECT customer_bk FROM v_stg_customer_l2
                                 WHERE op='UPSERT');"
  n="$(sql_scalar "SELECT COUNT(*) FROM customer WHERE valid_from='$q_bts';")"
  printf "    %-10s [%-11s]: %s new version(s)\n" "customer" "$mode" "$n"
fi

# ---- product -----------------------------------------------------------
if [ "$(feed_rows stg_product_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_product_l1)"
  ABS=""
  [ "$mode" = "FULL" ] && ABS="OR (c.is_deleted=0 AND c.sku NOT IN
        (SELECT product_bk FROM v_stg_product_l2))"
  sql_run "
    UPDATE product SET valid_to='$q_bts', is_current=0
    WHERE is_current=1 AND sku IN (
      SELECT c.sku FROM product c
      LEFT JOIN v_stg_product_l2 s ON s.product_bk = c.sku
      WHERE c.is_current=1 AND (
            (s.op='UPSERT' AND (s.diff_str <> c.diff_str OR c.is_deleted=1))
         OR (s.op='DELETE' AND c.is_deleted=0)
         $ABS ));
    INSERT INTO product(sku, product_name, price, currency, diff_str, valid_from)
    SELECT s.product_bk, s.prod_name, s.price, s.currency, s.diff_str, s.ldts
    FROM v_stg_product_l2 s
    WHERE s.op='UPSERT'
      AND NOT EXISTS (SELECT 1 FROM product c
                      WHERE c.sku=s.product_bk AND c.is_current=1);
    INSERT INTO product(sku, product_name, price, currency,
                        diff_str, valid_from, is_deleted)
    SELECT c.sku, c.product_name, c.price, c.currency, c.diff_str, '$q_bts', 1
    FROM product c
    WHERE c.valid_to='$q_bts' AND c.is_deleted=0
      AND c.sku NOT IN (SELECT product_bk FROM v_stg_product_l2 WHERE op='UPSERT');"
  n="$(sql_scalar "SELECT COUNT(*) FROM product WHERE valid_from='$q_bts';")"
  printf "    %-10s [%-11s]: %s new version(s)\n" "product" "$mode" "$n"
fi

# ---- orders (conformed at ingest) ---------------------------------------
if [ "$(feed_rows stg_order_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_order_l1)"
  ABS=""
  [ "$mode" = "FULL" ] && ABS="OR (c.is_deleted=0 AND c.order_ref NOT IN
        (SELECT order_bk FROM v_stg_order_l2))"
  sql_run "
    UPDATE orders SET valid_to='$q_bts', is_current=0
    WHERE is_current=1 AND order_ref IN (
      SELECT c.order_ref FROM orders c
      LEFT JOIN v_stg_order_l2 s ON s.order_bk = c.order_ref
      WHERE c.is_current=1 AND (
            (s.op='UPSERT' AND (s.diff_str <> c.diff_str OR c.is_deleted=1))
         OR (s.op='DELETE' AND c.is_deleted=0)
         $ABS ));
    INSERT INTO orders(order_ref, customer_ref, status, amount, currency,
                       placed_at, diff_str, valid_from)
    SELECT s.order_bk, s.customer_bk,
           COALESCE((SELECT r.status_name FROM order_status_ref r
                     WHERE r.status_code = s.status),
                    'UNKNOWN('||COALESCE(s.status,'')||')'),
           s.amount, s.currency, s.placed_at, s.diff_str, s.ldts
    FROM v_stg_order_l2 s
    WHERE s.op='UPSERT'
      AND NOT EXISTS (SELECT 1 FROM orders c
                      WHERE c.order_ref=s.order_bk AND c.is_current=1);
    INSERT INTO orders(order_ref, customer_ref, status, amount, currency,
                       placed_at, diff_str, valid_from, is_deleted)
    SELECT c.order_ref, c.customer_ref, c.status, c.amount, c.currency,
           c.placed_at, c.diff_str, '$q_bts', 1
    FROM orders c
    WHERE c.valid_to='$q_bts' AND c.is_deleted=0
      AND c.order_ref NOT IN (SELECT order_bk FROM v_stg_order_l2 WHERE op='UPSERT');"
  n="$(sql_scalar "SELECT COUNT(*) FROM orders WHERE valid_from='$q_bts';")"
  printf "    %-10s [%-11s]: %s new version(s)\n" "orders" "$mode" "$n"
fi

# ---- order lines ---------------------------------------------------------
if [ "$(feed_rows stg_order_line_l1)" -gt 0 ]; then
  sql_run "
    INSERT INTO order_line(order_ref, sku, valid_from)
    SELECT s.order_bk, s.product_bk, s.ldts
    FROM v_stg_order_line_l2 s
    WHERE s.op='UPSERT'
      AND NOT EXISTS (SELECT 1 FROM order_line l
                      WHERE l.order_ref=s.order_bk AND l.sku=s.product_bk);"
  n="$(sql_scalar "SELECT COUNT(*) FROM order_line;")"
  printf "    %-10s              : %s pair(s) total\n" "order_line" "$n"
fi
