#!/usr/bin/env bash
# Pretty-print the Unified Star Schema and its signature queries.
# Business sections mirror the sibling demos' query.sh.
source "$(dirname "$0")/lib.sh"
show() { echo; echo "### $1"; shift; sql_table "$1"; }

echo "======================================================================"
echo "  BUSINESS VIEWS  (every query starts FROM _bridge)"
echo "======================================================================"
show "Customers" "SELECT * FROM v_customer ORDER BY customer_ref;"
show "Products"  "SELECT * FROM v_product  ORDER BY sku;"
show "Orders"    "SELECT * FROM v_order    ORDER BY order_ref;"

echo; echo "======================================================================"
echo "  THE PUPPINI BRIDGE: one stage per table, keys + measures"
echo "======================================================================"
show "_bridge" \
  "SELECT stage, _key_customer, _key_orders, _key_order_line, _key_product,
          order_amount, line_count
   FROM _bridge
   ORDER BY CASE stage WHEN 'Customer' THEN 1 WHEN 'Product' THEN 2
                       WHEN 'Orders' THEN 3 ELSE 4 END,
            _key_customer, _key_orders, _key_product;"

echo; echo "======================================================================"
echo "  NO FAN TRAP: an order with two lines is not counted twice"
echo "======================================================================"
show "Order amount, three ways" "SELECT * FROM v_fan_trap;"
show "Sales by customer (amount + lines in one query)" \
  "SELECT * FROM v_sales_by_customer ORDER BY customer_ref;"
show "Sales by product" "SELECT * FROM v_sales_by_product ORDER BY sku;"

echo; echo "======================================================================"
echo "  HISTORY LIVES IN THE CORE (the USS is current state)"
echo "======================================================================"
show "Customer history" "SELECT * FROM v_customer_history;"
show "Orders as recorded" \
  "SELECT * FROM v_order_as_recorded ORDER BY order_ref, recorded_at;"
