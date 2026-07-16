#!/usr/bin/env bash
# Pretty-print the EDW's business views + its signature queries.
# Sections mirror the sibling demos' query.sh so outputs compare directly.
source "$(dirname "$0")/lib.sh"
show() { echo; echo "### $1"; shift; sql_table "$1"; }

echo "======================================================================"
echo "  TIME-VARIANT 3NF EDW  (current state; history in the same tables)"
echo "======================================================================"
show "Customers" "SELECT * FROM v_customer ORDER BY customer_ref;"
show "Products"  "SELECT * FROM v_product  ORDER BY sku;"
show "Orders"    "SELECT * FROM v_order    ORDER BY order_ref;"

echo; echo "======================================================================"
echo "  CONFORMED AT INGEST: the EDW stores PENDING (raw 'P' lives in the archive)"
echo "======================================================================"
show "Orders, every version, conformed values" \
  "SELECT order_ref, valid_from, status, amount, customer_ref, is_current, is_deleted
   FROM orders ORDER BY order_ref, valid_from;"

echo; echo "======================================================================"
echo "  TIME-VARIANT ROWS: current and history in one table"
echo "======================================================================"
show "Customer history" "SELECT * FROM v_customer_history;"

echo; echo "======================================================================"
echo "  POINT-IN-TIME, THE 3NF WAY: a RANGE join (the BETWEEN gymnastics)"
echo "======================================================================"
show "Orders as recorded" \
  "SELECT * FROM v_order_as_recorded ORDER BY order_ref, recorded_at;"
