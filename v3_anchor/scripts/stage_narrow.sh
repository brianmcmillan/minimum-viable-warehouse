#!/usr/bin/env bash
# ---------------------------------------------------------------------
# SECOND STAGING STEP -- wide stage -> narrow stage.
#   usage: stage_narrow.sh
#
# Deliveries arrive wide (one row per record, stg_*_l1) like every other
# model's, and the archive holds them wide. Focal's loaders read narrow
# key/value rows, so this step unpivots the wide stage into
# source_landing_stage. Both callers run it at the same point:
#
#   load_feed.sh -- after the wide rows are archived, before apply_delivery
#   rebuild.sh   -- after the wide rows are restored, before apply_delivery
#
# The rules, each asserted by the level-1 tests in tests/run_tests.sh
# (the same script as v3_focal-point/scripts/stage_narrow.sh):
#   * type routing  -- strings and units to value_str, price/amount to
#     value_num, signup_date/placed_at to value_ts;
#   * key rows      -- every record also emits its key as an attribute
#     (customer_ref, sku, order_ref; order lines key on order_ref~sku);
#   * nulls         -- a wide row restates the whole record, so an empty
#     column is emitted as SQL NULL, never skipped and never 'NULL';
#   * tombstones    -- a DELETE row emits exactly one _tombstone row;
#   * order         -- feed, then wide rowid, then a fixed attribute
#     position. Within one (key, attribute) the narrow rows keep their
#     wide rows' order, which the recency tiebreak (rowid DESC) reads, so
#     ingest and replay resolve duplicates identically.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

sql <<'SQL'
DELETE FROM source_landing_stage;
INSERT INTO source_landing_stage(source_system, source_entity, business_key, attribute_name,
                                 value_str, value_num, value_ts, extract_ts, op, load_mode)
SELECT source_system, source_entity, business_key, attribute_name,
       value_str, value_num, value_ts, extract_ts, op, load_mode
FROM (
  -- CRM.CUSTOMER  (key: customer_id)
  SELECT 1 AS feed, w.rowid AS wrow, a.pos, 'CRM' AS source_system, 'CUSTOMER' AS source_entity,
         w.customer_id AS business_key, a.attr AS attribute_name,
         CASE a.attr WHEN 'customer_ref' THEN w.customer_id WHEN 'full_name' THEN w.full_name
                     WHEN 'email_addr' THEN w.email_addr END AS value_str,
         NULL AS value_num,
         CASE a.attr WHEN 'signup_date' THEN w.signup_date END AS value_ts,
         w.extract_dt AS extract_ts, w.op, w.load_mode
  FROM stg_customer_l1 w
  JOIN (SELECT 1 pos, 'customer_ref' attr UNION ALL SELECT 2, 'full_name'
        UNION ALL SELECT 3, 'email_addr'  UNION ALL SELECT 4, 'signup_date'
        UNION ALL SELECT 0, '_tombstone') a
    ON (w.op = 'DELETE') = (a.attr = '_tombstone')
  UNION ALL
  -- PIM.PRODUCT  (key: sku)
  SELECT 2, w.rowid, a.pos, 'PIM', 'PRODUCT', w.sku, a.attr,
         CASE a.attr WHEN 'sku' THEN w.sku WHEN 'prod_name' THEN w.prod_name
                     WHEN 'currency' THEN w.currency END,
         CASE a.attr WHEN 'price' THEN w.price END,
         NULL,
         w.extract_dt, w.op, w.load_mode
  FROM stg_product_l1 w
  JOIN (SELECT 1 pos, 'sku' attr UNION ALL SELECT 2, 'prod_name'
        UNION ALL SELECT 3, 'price' UNION ALL SELECT 4, 'currency'
        UNION ALL SELECT 0, '_tombstone') a
    ON (w.op = 'DELETE') = (a.attr = '_tombstone')
  UNION ALL
  -- OMS.ORDER  (key: order_ref)
  SELECT 3, w.rowid, a.pos, 'OMS', 'ORDER', w.order_ref, a.attr,
         CASE a.attr WHEN 'order_ref' THEN w.order_ref WHEN 'customer_ref' THEN w.customer_ref
                     WHEN 'status' THEN w.status WHEN 'currency' THEN w.currency END,
         CASE a.attr WHEN 'amount' THEN w.amount END,
         CASE a.attr WHEN 'placed_at' THEN w.placed_at END,
         w.extract_dt, w.op, w.load_mode
  FROM stg_order_l1 w
  JOIN (SELECT 1 pos, 'order_ref' attr UNION ALL SELECT 2, 'customer_ref'
        UNION ALL SELECT 3, 'status' UNION ALL SELECT 4, 'amount'
        UNION ALL SELECT 5, 'currency' UNION ALL SELECT 6, 'placed_at'
        UNION ALL SELECT 0, '_tombstone') a
    ON (w.op = 'DELETE') = (a.attr = '_tombstone')
  UNION ALL
  -- OMS.ORDER_LINE  (key: order_ref~sku)
  SELECT 4, w.rowid, a.pos, 'OMS', 'ORDER_LINE', w.order_ref || '~' || w.sku, a.attr,
         CASE a.attr WHEN 'order_ref' THEN w.order_ref WHEN 'sku' THEN w.sku END,
         NULL, NULL,
         w.extract_dt, w.op, w.load_mode
  FROM stg_order_line_l1 w
  JOIN (SELECT 1 pos, 'order_ref' attr UNION ALL SELECT 2, 'sku'
        UNION ALL SELECT 0, '_tombstone') a
    ON (w.op = 'DELETE') = (a.attr = '_tombstone')
)
ORDER BY feed, wrow, pos;
SQL

w="$(sql_scalar "SELECT (SELECT COUNT(*) FROM stg_customer_l1) + (SELECT COUNT(*) FROM stg_product_l1)
                      + (SELECT COUNT(*) FROM stg_order_l1)    + (SELECT COUNT(*) FROM stg_order_line_l1);")"
n="$(sql_scalar "SELECT COUNT(*) FROM source_landing_stage;")"
echo "==> Staged narrow: $w wide row(s) -> $n key/value row(s)"
