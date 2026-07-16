#!/usr/bin/env bash
# ---------------------------------------------------------------------
# LINK LOADS -- relationship pairs, plus driving-key effectivity.
#
# Links are insert-only: one row per distinct pair, ever. History of
# WHICH pair is in force lives in the effectivity satellite.
#
# ORDER->CUSTOMER has a driving key (the order): when a delivery names a
# customer for an order, a new effsat row opens that pairing and thereby
# closes the previous one -- end dates are computed via LEAD on the way
# out, never written (the insert-only pattern from the DV101 Baseline).
# This is the re-pointing case the Focal demo's load_rel.sh does not yet
# handle.
#
# ORDER->PRODUCT has no driving key; pairs are additive facts.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Loading links & effectivity (ldts=$BATCH_TS)"
q_bts="$(sql_quote "$BATCH_TS")"

if [ "$(feed_rows stg_order_l1)" -gt 0 ]; then
  sql_run "
    INSERT INTO rv_order_customer_l(order_bk, customer_bk, ldts, rsrc)
    SELECT s.order_bk, s.customer_bk, s.ldts, s.rsrc
    FROM v_stg_order_l2 s
    WHERE s.op='UPSERT' AND s.customer_bk IS NOT NULL AND s.customer_bk <> ''
      AND NOT EXISTS (SELECT 1 FROM rv_order_customer_l l
                      WHERE l.order_bk=s.order_bk AND l.customer_bk=s.customer_bk);"

  # Effectivity: open the delivered pairing when it is not already the
  # current one for the driving key. old_customer_bk records what it
  # superseded (audit only; currency is computed, not stored).
  sql_run "
    INSERT INTO bv_order_customer_l_effsat
        (order_bk, customer_bk, ldts, rsrc, start_date, old_customer_bk)
    SELECT s.order_bk, s.customer_bk, s.ldts, s.rsrc, s.ldts, cur.customer_bk
    FROM v_stg_order_l2 s
    LEFT JOIN v_order_customer_current cur ON cur.order_bk = s.order_bk
    WHERE s.op='UPSERT' AND s.customer_bk IS NOT NULL AND s.customer_bk <> ''
      AND (cur.customer_bk IS NULL OR cur.customer_bk <> s.customer_bk);"
  n="$(sql_scalar "SELECT COUNT(*) FROM bv_order_customer_l_effsat WHERE ldts='$q_bts';")"
  printf "    %-28s : %s pairing change(s)\n" "order->customer (driving key)" "$n"
fi

if [ "$(feed_rows stg_order_line_l1)" -gt 0 ]; then
  sql_run "
    INSERT INTO rv_order_product_l(order_bk, product_bk, ldts, rsrc)
    SELECT s.order_bk, s.product_bk, s.ldts, s.rsrc
    FROM v_stg_order_line_l2 s
    WHERE s.op='UPSERT'
      AND NOT EXISTS (SELECT 1 FROM rv_order_product_l l
                      WHERE l.order_bk=s.order_bk AND l.product_bk=s.product_bk);"
  n="$(sql_scalar "SELECT COUNT(*) FROM rv_order_product_l WHERE ldts='$q_bts';")"
  printf "    %-28s : %s new pair(s)\n" "order->product" "$n"
fi
