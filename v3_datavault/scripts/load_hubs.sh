#!/usr/bin/env bash
# ---------------------------------------------------------------------
# HUB LOADS -- one row per business key, ever seen, from ANY feed that
# carries it. First arrival wins; ldts/rsrc record who introduced it.
#
# The training-package pattern reproduced here: a hub is loaded from
# every feed that carries its key, including LINK ENDS -- the customer
# hub loads from CRM.CUSTOMER *and* from OMS.ORDER's customer_ref, so a
# link can never dangle. Tombstones (op='DELETE') never create keys,
# matching the Focal demo's load_keys.sh.
#
# Only feeds present in this delivery are processed (empty stage tables
# are skipped), and each block is a plain INSERT ... WHERE NOT EXISTS:
# idempotent, insert-only, no surrogate sequence to coordinate.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Loading hubs (ldts=$BATCH_TS)"

n_before() { sql_scalar "SELECT COUNT(*) FROM $1;"; }
report()   { printf "    %-13s : %s new key(s)\n" "$1" "$2"; }

if [ "$(feed_rows stg_customer_l1)" -gt 0 ]; then
  b="$(n_before rv_customer_h)"
  sql_run "INSERT INTO rv_customer_h(customer_bk, ldts, rsrc)
           SELECT s.customer_bk, s.ldts, s.rsrc FROM v_stg_customer_l2 s
           WHERE s.op='UPSERT'
             AND NOT EXISTS (SELECT 1 FROM rv_customer_h h WHERE h.customer_bk=s.customer_bk);"
  report "rv_customer_h" "$(( $(n_before rv_customer_h) - b ))"
fi

if [ "$(feed_rows stg_product_l1)" -gt 0 ]; then
  b="$(n_before rv_product_h)"
  sql_run "INSERT INTO rv_product_h(product_bk, ldts, rsrc)
           SELECT s.product_bk, s.ldts, s.rsrc FROM v_stg_product_l2 s
           WHERE s.op='UPSERT'
             AND NOT EXISTS (SELECT 1 FROM rv_product_h h WHERE h.product_bk=s.product_bk);"
  report "rv_product_h" "$(( $(n_before rv_product_h) - b ))"
fi

if [ "$(feed_rows stg_order_l1)" -gt 0 ]; then
  b="$(n_before rv_order_h)"
  sql_run "INSERT INTO rv_order_h(order_bk, ldts, rsrc)
           SELECT s.order_bk, s.ldts, s.rsrc FROM v_stg_order_l2 s
           WHERE s.op='UPSERT'
             AND NOT EXISTS (SELECT 1 FROM rv_order_h h WHERE h.order_bk=s.order_bk);"
  report "rv_order_h" "$(( $(n_before rv_order_h) - b ))"

  # Link-end key: an order names its customer; make sure the hub has it.
  b="$(n_before rv_customer_h)"
  sql_run "INSERT INTO rv_customer_h(customer_bk, ldts, rsrc)
           SELECT DISTINCT s.customer_bk, s.ldts, s.rsrc FROM v_stg_order_l2 s
           WHERE s.op='UPSERT' AND s.customer_bk IS NOT NULL AND s.customer_bk <> ''
             AND NOT EXISTS (SELECT 1 FROM rv_customer_h h WHERE h.customer_bk=s.customer_bk);"
  report "  +cust (link end)" "$(( $(n_before rv_customer_h) - b ))"
fi

if [ "$(feed_rows stg_order_line_l1)" -gt 0 ]; then
  # Both ends of the order->product link.
  b="$(n_before rv_order_h)"
  sql_run "INSERT INTO rv_order_h(order_bk, ldts, rsrc)
           SELECT DISTINCT s.order_bk, s.ldts, s.rsrc FROM v_stg_order_line_l2 s
           WHERE s.op='UPSERT'
             AND NOT EXISTS (SELECT 1 FROM rv_order_h h WHERE h.order_bk=s.order_bk);"
  report "  +order (link end)" "$(( $(n_before rv_order_h) - b ))"
  b="$(n_before rv_product_h)"
  sql_run "INSERT INTO rv_product_h(product_bk, ldts, rsrc)
           SELECT DISTINCT s.product_bk, s.ldts, s.rsrc FROM v_stg_order_line_l2 s
           WHERE s.op='UPSERT'
             AND NOT EXISTS (SELECT 1 FROM rv_product_h h WHERE h.product_bk=s.product_bk);"
  report "  +prod (link end)" "$(( $(n_before rv_product_h) - b ))"
fi
