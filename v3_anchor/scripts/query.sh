#!/usr/bin/env bash
# Pretty-print the latest perspectives + Anchor's signature queries.
# Sections mirror the sibling demos' query.sh so outputs compare directly.
source "$(dirname "$0")/lib.sh"
show() { echo; echo "### $1"; shift; sql_table "$1"; }

echo "======================================================================"
echo "  LATEST PERSPECTIVES  (computed 'current' -- no end dates stored)"
echo "======================================================================"
show "Customers" "SELECT * FROM v_customer ORDER BY customer_ref;"
show "Products"  "SELECT * FROM v_product  ORDER BY sku;"
show "Orders"    "SELECT * FROM v_order    ORDER BY order_ref;"

echo; echo "======================================================================"
echo "  ATTRIBUTE-GRAIN HISTORY: one attribute's timeline, nothing else's"
echo "======================================================================"
show "Customer email history" "SELECT * FROM v_customer_email_history;"

echo; echo "======================================================================"
echo "  PRESENCE AS DATA: the EST knot timeline (no row_st anywhere)"
echo "======================================================================"
show "Existence assertions" "SELECT * FROM v_existence_history;"

echo; echo "======================================================================"
echo "  HISTORIZED TIE: which customer each order belongs to, when"
echo "======================================================================"
show "order->customer pairings" \
  "SELECT * FROM v_order_customer_history ORDER BY order_ref, start_ts;"

echo; echo "======================================================================"
echo "  THE CONSTELLATION: 24 tables where Focal has 4"
echo "======================================================================"
show "Table census" \
  "SELECT CASE WHEN name LIKE '%\_Existence' ESCAPE '\' THEN 'attribute (existence)'
               WHEN name IN ('CU_Customer','PR_Product','OD_Order') THEN 'anchor'
               WHEN name IN ('EST_ExistenceStatus','OST_OrderStatus','CUR_Currency') THEN 'knot'
               WHEN name LIKE 'OD\_placed\_%' ESCAPE '\' OR name LIKE 'OD\_part\_%' ESCAPE '\' THEN 'tie'
               ELSE 'attribute' END AS kind,
          COUNT(*) AS tables
   FROM sqlite_master WHERE type='table'
     AND (name LIKE 'CU\_%' ESCAPE '\' OR name LIKE 'PR\_%' ESCAPE '\'
       OR name LIKE 'OD\_%' ESCAPE '\'
       OR name IN ('EST_ExistenceStatus','OST_OrderStatus','CUR_Currency'))
   GROUP BY kind ORDER BY kind;"
