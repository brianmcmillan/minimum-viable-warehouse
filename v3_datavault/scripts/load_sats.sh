#!/usr/bin/env bash
# ---------------------------------------------------------------------
# SATELLITE LOADS -- descriptive history + status tracking.
#
# Descriptive sats (whole-row grain): insert a stage row only when its
# diff_str differs from the key's NEWEST satellite row. That comparison
# is the entire delta engine -- the DV counterpart of the Focal demo's
# NEW/CHANGE/NOCHANGE classification, done per ROW here rather than per
# atomic context. An unchanged re-delivery writes nothing.
#
# Status-tracking sats implement the shared safety rule:
#   'I'  -- key upserted while its latest status is missing or 'D'
#   'D'  -- explicit tombstone (op='DELETE'), ALWAYS
#   'D'  -- key absent from the delivery, ONLY when the delivery is FULL
# An INCREMENTAL delivery never infers a delete from absence. Change-only:
# a key already in the asserted state writes nothing.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Loading satellites (ldts=$BATCH_TS)"
q_bts="$(sql_quote "$BATCH_TS")"

report() { printf "    %-22s [%-11s]: %s row(s)\n" "$1" "$2" "$3"; }
n_at()   { sql_scalar "SELECT COUNT(*) FROM $1 WHERE ldts='$q_bts';"; }

# ---- CRM.CUSTOMER -----------------------------------------------------
if [ "$(feed_rows stg_customer_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_customer_l1)"

  sql_run "
    INSERT INTO rv_customer_hsat(customer_bk, ldts, rsrc, diff_str,
                                 full_name, email_addr, signup_date)
    SELECT s.customer_bk, s.ldts, s.rsrc, s.diff_str,
           s.full_name, s.email_addr, s.signup_date
    FROM v_stg_customer_l2 s
    LEFT JOIN (SELECT customer_bk, diff_str, ROW_NUMBER() OVER (
                 PARTITION BY customer_bk ORDER BY ldts DESC) rn
               FROM rv_customer_hsat) t
           ON t.customer_bk = s.customer_bk AND t.rn = 1
    WHERE s.op='UPSERT' AND (t.customer_bk IS NULL OR t.diff_str <> s.diff_str);"

  ABS=""
  [ "$mode" = "FULL" ] && ABS="
    INSERT INTO rv_customer_sts(customer_bk, ldts, rsrc, sts)
    SELECT c.customer_bk, '$q_bts', 'CRM.CUSTOMER', 'D'
    FROM v_customer_sts_current c
    WHERE c.sts='I' AND c.rsrc='CRM.CUSTOMER'
      AND NOT EXISTS (SELECT 1 FROM v_stg_customer_l2 s
                      WHERE s.customer_bk=c.customer_bk);"
  sql_run "
    INSERT INTO rv_customer_sts(customer_bk, ldts, rsrc, sts)
    SELECT s.customer_bk, s.ldts, s.rsrc, 'I' FROM v_stg_customer_l2 s
    WHERE s.op='UPSERT' AND COALESCE((SELECT c.sts FROM v_customer_sts_current c
                                      WHERE c.customer_bk=s.customer_bk),'D') = 'D';
    INSERT INTO rv_customer_sts(customer_bk, ldts, rsrc, sts)
    SELECT s.customer_bk, s.ldts, s.rsrc, 'D' FROM v_stg_customer_l2 s
    WHERE s.op='DELETE' AND COALESCE((SELECT c.sts FROM v_customer_sts_current c
                                      WHERE c.customer_bk=s.customer_bk),'D') = 'I';
    $ABS"
  report "rv_customer_hsat/_sts" "$mode" "$(( $(n_at rv_customer_hsat) + $(n_at rv_customer_sts) ))"
fi

# ---- PIM.PRODUCT ------------------------------------------------------
if [ "$(feed_rows stg_product_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_product_l1)"

  sql_run "
    INSERT INTO rv_product_hsat(product_bk, ldts, rsrc, diff_str,
                                prod_name, price, currency)
    SELECT s.product_bk, s.ldts, s.rsrc, s.diff_str, s.prod_name, s.price, s.currency
    FROM v_stg_product_l2 s
    LEFT JOIN (SELECT product_bk, diff_str, ROW_NUMBER() OVER (
                 PARTITION BY product_bk ORDER BY ldts DESC) rn
               FROM rv_product_hsat) t
           ON t.product_bk = s.product_bk AND t.rn = 1
    WHERE s.op='UPSERT' AND (t.product_bk IS NULL OR t.diff_str <> s.diff_str);"

  ABS=""
  [ "$mode" = "FULL" ] && ABS="
    INSERT INTO rv_product_sts(product_bk, ldts, rsrc, sts)
    SELECT c.product_bk, '$q_bts', 'PIM.PRODUCT', 'D'
    FROM v_product_sts_current c
    WHERE c.sts='I' AND c.rsrc='PIM.PRODUCT'
      AND NOT EXISTS (SELECT 1 FROM v_stg_product_l2 s
                      WHERE s.product_bk=c.product_bk);"
  sql_run "
    INSERT INTO rv_product_sts(product_bk, ldts, rsrc, sts)
    SELECT s.product_bk, s.ldts, s.rsrc, 'I' FROM v_stg_product_l2 s
    WHERE s.op='UPSERT' AND COALESCE((SELECT c.sts FROM v_product_sts_current c
                                      WHERE c.product_bk=s.product_bk),'D') = 'D';
    INSERT INTO rv_product_sts(product_bk, ldts, rsrc, sts)
    SELECT s.product_bk, s.ldts, s.rsrc, 'D' FROM v_stg_product_l2 s
    WHERE s.op='DELETE' AND COALESCE((SELECT c.sts FROM v_product_sts_current c
                                      WHERE c.product_bk=s.product_bk),'D') = 'I';
    $ABS"
  report "rv_product_hsat/_sts" "$mode" "$(( $(n_at rv_product_hsat) + $(n_at rv_product_sts) ))"
fi

# ---- OMS.ORDER --------------------------------------------------------
if [ "$(feed_rows stg_order_l1)" -gt 0 ]; then
  mode="$(feed_mode stg_order_l1)"

  sql_run "
    INSERT INTO rv_order_hsat(order_bk, ldts, rsrc, diff_str,
                              status, amount, currency, placed_at)
    SELECT s.order_bk, s.ldts, s.rsrc, s.diff_str,
           s.status, s.amount, s.currency, s.placed_at
    FROM v_stg_order_l2 s
    LEFT JOIN (SELECT order_bk, diff_str, ROW_NUMBER() OVER (
                 PARTITION BY order_bk ORDER BY ldts DESC) rn
               FROM rv_order_hsat) t
           ON t.order_bk = s.order_bk AND t.rn = 1
    WHERE s.op='UPSERT' AND (t.order_bk IS NULL OR t.diff_str <> s.diff_str);"

  ABS=""
  [ "$mode" = "FULL" ] && ABS="
    INSERT INTO rv_order_sts(order_bk, ldts, rsrc, sts)
    SELECT c.order_bk, '$q_bts', 'OMS.ORDER', 'D'
    FROM v_order_sts_current c
    WHERE c.sts='I' AND c.rsrc='OMS.ORDER'
      AND NOT EXISTS (SELECT 1 FROM v_stg_order_l2 s
                      WHERE s.order_bk=c.order_bk);"
  sql_run "
    INSERT INTO rv_order_sts(order_bk, ldts, rsrc, sts)
    SELECT s.order_bk, s.ldts, s.rsrc, 'I' FROM v_stg_order_l2 s
    WHERE s.op='UPSERT' AND COALESCE((SELECT c.sts FROM v_order_sts_current c
                                      WHERE c.order_bk=s.order_bk),'D') = 'D';
    INSERT INTO rv_order_sts(order_bk, ldts, rsrc, sts)
    SELECT s.order_bk, s.ldts, s.rsrc, 'D' FROM v_stg_order_l2 s
    WHERE s.op='DELETE' AND COALESCE((SELECT c.sts FROM v_order_sts_current c
                                      WHERE c.order_bk=s.order_bk),'D') = 'I';
    $ABS"
  report "rv_order_hsat/_sts" "$mode" "$(( $(n_at rv_order_hsat) + $(n_at rv_order_sts) ))"
fi
