#!/usr/bin/env bash
# Pretty-print the star + its signature queries. Sections mirror the
# sibling demos' query.sh so outputs compare directly across models.
source "$(dirname "$0")/lib.sh"
show() { echo; echo "### $1"; shift; sql_table "$1"; }

echo "======================================================================"
echo "  KIMBALL STAR  (facts + conformed dimensions)"
echo "======================================================================"
show "Customers (current, not deleted)" "SELECT * FROM mart_customers ORDER BY customer_ref;"
show "Products (current, not deleted)"  "SELECT * FROM mart_products  ORDER BY sku;"
show "Orders"                           "SELECT * FROM mart_orders    ORDER BY order_ref;"

echo; echo "======================================================================"
echo "  SCD TYPE 2: every customer version, with its validity window"
echo "======================================================================"
show "dim_customer history" "SELECT * FROM v_customer_history;"

echo; echo "======================================================================"
echo "  POINT-IN-TIME VIA FROZEN KEYS: facts keep the version they saw"
echo "======================================================================"
show "fact_orders (surrogates, not names)" \
  "SELECT order_ref, placed_date_key, customer_key, status_key, amount
   FROM fact_orders ORDER BY order_ref;"

echo; echo "======================================================================"
echo "  THE STAR, JOINED: order lines with all dimensions decoded"
echo "======================================================================"
show "v_star_order_lines" "SELECT * FROM v_star_order_lines ORDER BY order_ref, product_name;"

echo; echo "======================================================================"
echo "  DIM_DATE: the generated calendar dimension (sample)"
echo "======================================================================"
show "February 2026 (first week)" \
  "SELECT date_key, full_date, month_name, day, weekday FROM dim_date
   WHERE date_key BETWEEN 20260201 AND 20260207;"
