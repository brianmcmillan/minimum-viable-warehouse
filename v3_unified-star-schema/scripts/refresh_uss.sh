#!/usr/bin/env bash
# ---------------------------------------------------------------------
# USS REFRESH -- re-derive the whole presentation layer from the core, in
# one transaction. Full refresh, not incremental: the USS holds nothing
# the core doesn't, so recomputing it is always safe and always correct.
#
#   1. Tables: current, non-deleted core rows, each with its own
#      _key_<table>. Foreign keys are dropped; they move to the bridge.
#      The status decode (ref_order_status) is applied here.
#   2. Bridge: one stage per table. Each stage row carries its own key
#      plus every key reachable many-to-one -- the order line reaches its
#      customer THROUGH its order. Measures go on their own stage only.
#
# Bridge keys come from the core rows as recorded, even when the target
# is gone: O-101 keeps _key_customer='C002' after C002 is deleted, so its
# amount still counts; the LEFT JOIN to customer simply finds no name.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

sql_run "
BEGIN;
DELETE FROM _bridge; DELETE FROM order_line; DELETE FROM orders;
DELETE FROM product; DELETE FROM customer;   DELETE FROM uss_refresh;

INSERT INTO customer(_key_customer, customer_ref, customer_name, email, signup_date)
SELECT customer_id, customer_id, full_name, email_addr, signup_date
FROM v_latest__customer WHERE change_type <> 'DELETE';

INSERT INTO product(_key_product, sku, product_name, price, currency)
SELECT sku, sku, prod_name, price, currency
FROM v_latest__product WHERE change_type <> 'DELETE';

INSERT INTO orders(_key_orders, order_ref, status, status_code, amount, currency, placed_at)
SELECT o.order_ref, o.order_ref,
       COALESCE(r.status_name, 'UNKNOWN(' || COALESCE(o.status,'') || ')'),
       o.status, o.amount, o.currency, o.placed_at
FROM v_latest__order o
LEFT JOIN ref_order_status r ON r.status_code = o.status
WHERE o.change_type <> 'DELETE';

INSERT INTO order_line(_key_order_line, order_ref, sku)
SELECT order_ref || '|' || sku, order_ref, sku
FROM v_latest__order_line WHERE change_type <> 'DELETE';

-- Stage 'Customer': every customer, so order-less ones still appear.
INSERT INTO _bridge(stage, _key_customer)
SELECT 'Customer', _key_customer FROM customer;

-- Stage 'Product': every product.
INSERT INTO _bridge(stage, _key_product)
SELECT 'Product', _key_product FROM product;

-- Stage 'Orders': the order, the customer it points at, the order amount.
INSERT INTO _bridge(stage, _key_orders, _key_customer, order_amount)
SELECT 'Orders', o._key_orders, c.customer_ref, o.amount
FROM orders o
JOIN v_latest__order c ON c.order_ref = o.order_ref;

-- Stage 'Order line': the line, its order, its product, AND its order's
-- customer (the transitive many-to-one path). One line = line_count 1.
INSERT INTO _bridge(stage, _key_order_line, _key_orders, _key_product, _key_customer, line_count)
SELECT 'Order line', l._key_order_line, l.order_ref, l.sku, c.customer_ref, 1
FROM order_line l
LEFT JOIN v_latest__order c ON c.order_ref = l.order_ref AND c.change_type <> 'DELETE';

INSERT INTO uss_refresh(refreshed_for_load_ts, record_source)
SELECT batch_ts, file_id FROM load_params;
COMMIT;"

printf "    %-16s              : %s bridge row(s) across %s stage(s)\n" "_bridge" \
  "$(sql_scalar "SELECT COUNT(*) FROM _bridge;")" \
  "$(sql_scalar "SELECT COUNT(DISTINCT stage) FROM _bridge;")"
