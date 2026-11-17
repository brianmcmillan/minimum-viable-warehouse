#!/usr/bin/env bash
# ---------------------------------------------------------------------
# QUERY-ASSIST REFRESH -- rewrite the business vault's generated tables:
# bv_customer_cpit, bv_product_cpit, bv_order_cpit and bv_order_bridge.
#
# These four are generated query-assist tables, deleted and rewritten in
# full on every refresh. Nothing else in the vault is: every rv_* table
# and the effectivity satellite are insert-only and their triggers abort
# any UPDATE or DELETE. Called last by apply_delivery.sh, so ingest and
# `make rebuild` refresh them alike. One transaction: a reader never
# sees a half-written CPIT.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Refreshing query-assist tables (CPIT x3, order bridge)"

# The ghost pointer's ldts, and the reserved keys no CPIT row is for.
GHOST="'1900-01-01 00:00:00'"
RESERVED="('0','-1','-2')"

db -bail <<SQL   # -bail: an error stops before COMMIT, so the old tables stay
BEGIN;
DELETE FROM bv_customer_cpit;
DELETE FROM bv_product_cpit;
DELETE FROM bv_order_cpit;
DELETE FROM bv_order_bridge;

INSERT INTO bv_customer_cpit(customer_bk, hsat_bk, hsat_ldts, sts_bk, sts_ldts)
SELECT h.customer_bk,
       CASE WHEN s.ldts IS NULL THEN '0' ELSE h.customer_bk END, COALESCE(s.ldts, $GHOST),
       CASE WHEN t.ldts IS NULL THEN '0' ELSE h.customer_bk END, COALESCE(t.ldts, $GHOST)
FROM rv_customer_h h
LEFT JOIN (SELECT customer_bk, MAX(ldts) ldts FROM rv_customer_hsat GROUP BY customer_bk) s
       ON s.customer_bk = h.customer_bk
LEFT JOIN (SELECT customer_bk, MAX(ldts) ldts FROM rv_customer_sts  GROUP BY customer_bk) t
       ON t.customer_bk = h.customer_bk
WHERE h.customer_bk NOT IN $RESERVED;

INSERT INTO bv_product_cpit(product_bk, hsat_bk, hsat_ldts, sts_bk, sts_ldts)
SELECT h.product_bk,
       CASE WHEN s.ldts IS NULL THEN '0' ELSE h.product_bk END, COALESCE(s.ldts, $GHOST),
       CASE WHEN t.ldts IS NULL THEN '0' ELSE h.product_bk END, COALESCE(t.ldts, $GHOST)
FROM rv_product_h h
LEFT JOIN (SELECT product_bk, MAX(ldts) ldts FROM rv_product_hsat GROUP BY product_bk) s
       ON s.product_bk = h.product_bk
LEFT JOIN (SELECT product_bk, MAX(ldts) ldts FROM rv_product_sts  GROUP BY product_bk) t
       ON t.product_bk = h.product_bk
WHERE h.product_bk NOT IN $RESERVED;

-- The current effectivity row is the newest per driving key, by the
-- same (start_date, ldts) order v_order_customer_eff_history uses.
INSERT INTO bv_order_cpit(order_bk, hsat_bk, hsat_ldts, sts_bk, sts_ldts,
                          eff_customer_bk, eff_ldts)
SELECT h.order_bk,
       CASE WHEN s.ldts IS NULL THEN '0' ELSE h.order_bk END, COALESCE(s.ldts, $GHOST),
       CASE WHEN t.ldts IS NULL THEN '0' ELSE h.order_bk END, COALESCE(t.ldts, $GHOST),
       COALESCE(e.customer_bk, '0'), COALESCE(e.ldts, $GHOST)
FROM rv_order_h h
LEFT JOIN (SELECT order_bk, MAX(ldts) ldts FROM rv_order_hsat GROUP BY order_bk) s
       ON s.order_bk = h.order_bk
LEFT JOIN (SELECT order_bk, MAX(ldts) ldts FROM rv_order_sts  GROUP BY order_bk) t
       ON t.order_bk = h.order_bk
LEFT JOIN (SELECT order_bk, customer_bk, ldts FROM (
             SELECT order_bk, customer_bk, ldts, ROW_NUMBER() OVER (
                      PARTITION BY order_bk ORDER BY start_date DESC, ldts DESC) rn
             FROM bv_order_customer_l_effsat) WHERE rn = 1) e
       ON e.order_bk = h.order_bk
WHERE h.order_bk NOT IN $RESERVED;

INSERT INTO bv_order_bridge(order_bk, product_bk, customer_bk)
SELECT l.order_bk, l.product_bk, COALESCE(c.customer_bk, '0')
FROM rv_order_product_l l
LEFT JOIN v_order_customer_current c ON c.order_bk = l.order_bk;
COMMIT;
SQL
printf "    %-16s : %s / %s / %s row(s)\n" "cpit cust/prod/ord" \
  "$(sql_scalar 'SELECT COUNT(*) FROM bv_customer_cpit;')" \
  "$(sql_scalar 'SELECT COUNT(*) FROM bv_product_cpit;')" \
  "$(sql_scalar 'SELECT COUNT(*) FROM bv_order_cpit;')"
printf "    %-16s : %s row(s)\n" "order bridge" "$(sql_scalar 'SELECT COUNT(*) FROM bv_order_bridge;')"
