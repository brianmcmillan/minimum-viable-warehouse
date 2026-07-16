#!/usr/bin/env bash
# Pretty-print the info mart + the vault's signature audit queries.
# Sections mirror the Focal demo's query.sh so outputs compare directly.
source "$(dirname "$0")/lib.sh"
show() { echo; echo "### $1"; shift; sql_table "$1"; }

echo "======================================================================"
echo "  INFO MART  (raw vault + soft rules = business views)"
echo "======================================================================"
show "Customers"  "SELECT * FROM dim_customer ORDER BY customer_ref;"
show "Products"   "SELECT * FROM dim_product  ORDER BY sku;"
show "Orders"     "SELECT * FROM fact_order   ORDER BY order_ref;"

echo; echo "======================================================================"
echo "  HARD vs SOFT RULES: the vault stores 'P'; the mart says PENDING"
echo "======================================================================"
show "Order status history (raw beside translated)" \
  "SELECT * FROM v_order_status_history;"

echo; echo "======================================================================"
echo "  PRESENCE TIMELINE: every insert/delete assertion, per key"
echo "======================================================================"
show "Status-tracking satellites" "SELECT * FROM v_status_history;"

echo; echo "======================================================================"
echo "  DRIVING-KEY EFFECTIVITY: which customer each order belongs to, when"
echo "======================================================================"
show "order->customer pairings" \
  "SELECT order_bk, customer_bk, start_date, end_date, iscurrent
   FROM v_order_customer_eff_history ORDER BY order_bk, start_date;"

echo; echo "======================================================================"
echo "  ROW LINEAGE: rsrc + ldts ride on every vault row"
echo "======================================================================"
show "Customer satellite rows" \
  "SELECT customer_bk, ldts, rsrc, full_name, email_addr FROM rv_customer_hsat
   ORDER BY customer_bk, ldts;"
