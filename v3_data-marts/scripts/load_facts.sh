#!/usr/bin/env bash
# ---------------------------------------------------------------------
# FACT LOADER -- transaction-grain inserts, restatement UPDATEs.
#
# New orders INSERT with customer_key FROZEN to the SCD2 version current
# right now (load_dims.sh has already run, so "now" includes this
# delivery's changes). Later dimension versions never touch the fact.
#
# A RESTATED order -- same order_ref, different content, including a
# re-pointed customer -- is an UPDATE in place. This is the deliberate
# Kimball contrast with both sibling demos: Focal and DV never mutate;
# the star does, and the PSA is what keeps that honest (every prior
# state is still in psa_order, and rebuild reapplies the history).
#
# Unknown-member seeds (-1) absorb codes and dates the dimensions have
# never heard of instead of dropping or crashing the load.
# Fact deletes are out of scope: no delivery tombstones an order, and a
# transactional star would keep the row anyway.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Loading facts (batch_ts=$BATCH_TS)"
q_bts="$(sql_quote "$BATCH_TS")"

# Idempotent unknown members (schema seeds the known ones).
sql_run "INSERT OR IGNORE INTO dim_order_status(status_key,status_code,status_name)
         VALUES(-1,'?','UNKNOWN');
         INSERT OR IGNORE INTO dim_date(date_key,full_date,year,month,month_name,day,weekday)
         VALUES(-1,'unknown',0,0,'Unknown',0,'Unknown');"

if [ "$(feed_rows stg_order_l1)" -gt 0 ]; then
  # New orders.
  sql_run "
    INSERT INTO fact_orders(order_ref, placed_date_key, customer_key,
                            status_key, amount, currency, placed_at)
    SELECT s.order_bk,
           COALESCE((SELECT date_key FROM dim_date
                     WHERE date_key = CAST(STRFTIME('%Y%m%d', s.placed_at) AS INTEGER)), -1),
           (SELECT c.customer_key FROM dim_customer c
             WHERE c.customer_ref = s.customer_bk AND c.is_current=1),
           COALESCE((SELECT status_key FROM dim_order_status
                     WHERE status_code = s.status), -1),
           s.amount, s.currency, s.placed_at
    FROM v_stg_order_l2 s
    WHERE s.op='UPSERT'
      AND s.customer_bk IS NOT NULL AND s.customer_bk <> ''
      AND NOT EXISTS (SELECT 1 FROM fact_orders f WHERE f.order_ref = s.order_bk)
    ORDER BY s.order_bk;"

  # Restated orders: update in place, only when something really differs.
  sql_run "
    UPDATE fact_orders SET
      amount    = (SELECT s.amount    FROM v_stg_order_l2 s WHERE s.order_bk=fact_orders.order_ref),
      currency  = (SELECT s.currency  FROM v_stg_order_l2 s WHERE s.order_bk=fact_orders.order_ref),
      placed_at = (SELECT s.placed_at FROM v_stg_order_l2 s WHERE s.order_bk=fact_orders.order_ref),
      placed_date_key = (SELECT COALESCE((SELECT date_key FROM dim_date
                          WHERE date_key = CAST(STRFTIME('%Y%m%d', s.placed_at) AS INTEGER)), -1)
                         FROM v_stg_order_l2 s WHERE s.order_bk=fact_orders.order_ref),
      status_key = (SELECT COALESCE((SELECT status_key FROM dim_order_status
                          WHERE status_code = s.status), -1)
                    FROM v_stg_order_l2 s WHERE s.order_bk=fact_orders.order_ref),
      customer_key = (SELECT c.customer_key FROM v_stg_order_l2 s
                      JOIN dim_customer c ON c.customer_ref = s.customer_bk
                                         AND c.is_current=1
                      WHERE s.order_bk=fact_orders.order_ref)
    WHERE order_ref IN (
      SELECT s.order_bk FROM v_stg_order_l2 s
      JOIN fact_orders f ON f.order_ref = s.order_bk
      WHERE s.op='UPSERT'
        AND ( s.amount    IS NOT f.amount
           OR s.currency  IS NOT f.currency
           OR s.placed_at IS NOT f.placed_at
           OR COALESCE((SELECT status_key FROM dim_order_status
                        WHERE status_code=s.status),-1) <> f.status_key
           OR s.customer_bk <> (SELECT customer_ref FROM dim_customer
                                WHERE customer_key = f.customer_key) ));"
  n="$(sql_scalar "SELECT COUNT(*) FROM fact_orders;")"
  printf "    %-16s : %s row(s) total\n" "fact_orders" "$n"
fi

if [ "$(feed_rows stg_order_line_l1)" -gt 0 ]; then
  sql_run "
    INSERT INTO fact_order_lines(order_ref, product_key, placed_date_key)
    SELECT s.order_bk,
           (SELECT p.product_key FROM dim_product p
             WHERE p.sku = s.product_bk AND p.is_current=1),
           COALESCE((SELECT placed_date_key FROM fact_orders f
                     WHERE f.order_ref = s.order_bk), -1)
    FROM v_stg_order_line_l2 s
    WHERE s.op='UPSERT'
      AND NOT EXISTS (SELECT 1 FROM fact_order_lines l
                      WHERE l.order_ref=s.order_bk
                        AND l.product_key=(SELECT p.product_key FROM dim_product p
                                           WHERE p.sku=s.product_bk AND p.is_current=1))
    ORDER BY s.order_bk, s.product_bk;"
  n="$(sql_scalar "SELECT COUNT(*) FROM fact_order_lines;")"
  printf "    %-16s : %s row(s) total\n" "fact_order_lines" "$n"
fi
