#!/usr/bin/env bash
# ---------------------------------------------------------------------
# THE TRANSFORM. All of it. Full recomputation of the latest tables from
# the archive -- idempotent by construction, no incremental state.
#
# Everything the sibling demos implement as load-time state machines is
# ONE query here, per feed:
#
#   latest mention per key : newest row (load_seq, extract_dt, seq_nbr)
#   deleted                : latest mention is a tombstone, OR any FULL
#                            delivery of the feed came after it (if the
#                            key had been in that snapshot, THAT would be
#                            the latest mention -- so a later FULL means
#                            absence). The shared safety rule, derived
#                            from the log instead of enforced during it.
#   latest values          : newest UPSERT mention
#
# Read the length of this file as data, not accident: this complexity
# exists in every demo -- the others pay it once at load time; OBT
# pays it on every refresh, and every consumer who bypasses these
# tables pays it again.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Full refresh of latest tables from the archive"

adb <<'SQL'
DELETE FROM obt_customer;
DELETE FROM obt_product;
DELETE FROM obt_orders;
DELETE FROM obt_order_lines;
DELETE FROM obt_order_wide;

-- ---- customers --------------------------------------------------------
WITH ranked AS (
  SELECT customer_id, full_name, email_addr, signup_date, op, load_seq,
         ROW_NUMBER() OVER (PARTITION BY customer_id
                            ORDER BY load_seq DESC, extract_dt DESC, seq_nbr DESC) rn
  FROM arch.hist_customer),
ranked_up AS (
  SELECT customer_id, full_name, email_addr, signup_date,
         ROW_NUMBER() OVER (PARTITION BY customer_id
                            ORDER BY load_seq DESC, extract_dt DESC, seq_nbr DESC) rn
  FROM arch.hist_customer WHERE op='UPSERT'),
fulls AS (SELECT DISTINCT load_seq FROM arch.hist_customer WHERE load_mode='FULL'),
alive AS (
  SELECT m.customer_id FROM ranked m
  WHERE m.rn=1 AND m.op<>'DELETE'
    AND NOT EXISTS (SELECT 1 FROM fulls f WHERE f.load_seq > m.load_seq))
INSERT INTO obt_customer(customer_ref, full_name, email, signup_date)
SELECT u.customer_id, u.full_name, u.email_addr, u.signup_date
FROM ranked_up u JOIN alive a ON a.customer_id = u.customer_id
WHERE u.rn=1;

-- ---- products ----------------------------------------------------------
WITH ranked AS (
  SELECT sku, op, load_seq,
         ROW_NUMBER() OVER (PARTITION BY sku
                            ORDER BY load_seq DESC, extract_dt DESC, seq_nbr DESC) rn
  FROM arch.hist_product),
ranked_up AS (
  SELECT sku, prod_name, price, currency,
         ROW_NUMBER() OVER (PARTITION BY sku
                            ORDER BY load_seq DESC, extract_dt DESC, seq_nbr DESC) rn
  FROM arch.hist_product WHERE op='UPSERT'),
fulls AS (SELECT DISTINCT load_seq FROM arch.hist_product WHERE load_mode='FULL'),
alive AS (
  SELECT m.sku FROM ranked m
  WHERE m.rn=1 AND m.op<>'DELETE'
    AND NOT EXISTS (SELECT 1 FROM fulls f WHERE f.load_seq > m.load_seq))
INSERT INTO obt_product(sku, product_name, price, currency)
SELECT u.sku, u.prod_name, u.price, u.currency
FROM ranked_up u JOIN alive a ON a.sku = u.sku
WHERE u.rn=1;

-- ---- orders --------------------------------------------------------------
WITH ranked AS (
  SELECT order_ref, op, load_seq,
         ROW_NUMBER() OVER (PARTITION BY order_ref
                            ORDER BY load_seq DESC, extract_dt DESC, seq_nbr DESC) rn
  FROM arch.hist_order),
ranked_up AS (
  SELECT order_ref, customer_ref, status, amount, currency, placed_at,
         ROW_NUMBER() OVER (PARTITION BY order_ref
                            ORDER BY load_seq DESC, extract_dt DESC, seq_nbr DESC) rn
  FROM arch.hist_order WHERE op='UPSERT'),
fulls AS (SELECT DISTINCT load_seq FROM arch.hist_order WHERE load_mode='FULL'),
alive AS (
  SELECT m.order_ref FROM ranked m
  WHERE m.rn=1 AND m.op<>'DELETE'
    AND NOT EXISTS (SELECT 1 FROM fulls f WHERE f.load_seq > m.load_seq))
INSERT INTO obt_orders(order_ref, customer_ref, status, amount, currency, placed_at)
SELECT u.order_ref, u.customer_ref, u.status, u.amount, u.currency, u.placed_at
FROM ranked_up u JOIN alive a ON a.order_ref = u.order_ref
WHERE u.rn=1;

-- ---- order lines (additive pairs; no line deletes in scope) ---------------
INSERT INTO obt_order_lines(order_ref, sku)
SELECT DISTINCT order_ref, sku FROM arch.hist_order_line WHERE op='UPSERT';

-- ---- the One Big Table: order-line grain, everything denormalized ---------
INSERT INTO obt_order_wide(order_ref, placed_at, status, amount, currency,
                           customer_ref, customer_name, email,
                           sku, product_name, price)
SELECT o.order_ref, o.placed_at, o.status, o.amount, o.currency,
       o.customer_ref, c.full_name, c.email,
       l.sku, p.product_name, p.price
FROM obt_orders o
JOIN obt_order_lines l ON l.order_ref = o.order_ref
LEFT JOIN obt_customer c ON c.customer_ref = o.customer_ref
LEFT JOIN obt_product  p ON p.sku = l.sku;
SQL

echo "    customers=$(sql_scalar 'SELECT COUNT(*) FROM obt_customer')" \
     "products=$(sql_scalar 'SELECT COUNT(*) FROM obt_product')" \
     "orders=$(sql_scalar 'SELECT COUNT(*) FROM obt_orders')" \
     "wide=$(sql_scalar 'SELECT COUNT(*) FROM obt_order_wide')"
