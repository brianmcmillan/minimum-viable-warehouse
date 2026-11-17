#!/usr/bin/env bash
# Pretty-print the Activity Schema warehouse: the streams, the business
# views, and the temporal-join signature queries. Business sections
# mirror the sibling demos' query.sh so outputs compare directly.
source "$(dirname "$0")/lib.sh"
show() { echo; echo "### $1"; shift; sql_table "$1"; }

echo "======================================================================"
echo "  THE MODEL IS TWO STREAMS: an entity doing an activity at a moment"
echo "======================================================================"
show "customer_stream" \
  "SELECT activity_id, ts, customer, activity, link, revenue_impact, feature_json, _record_source
   FROM customer_stream ORDER BY customer, ts, _seq;"
show "product_stream" \
  "SELECT activity_id, ts, customer AS sku, activity, link, feature_json, _record_source
   FROM product_stream ORDER BY customer, ts, _seq;"

echo; echo "======================================================================"
echo "  BUSINESS VIEWS  (current state = LAST EVER per attribute)"
echo "======================================================================"
show "Customers" "SELECT * FROM v_customer ORDER BY customer_ref;"
show "Products"  "SELECT * FROM v_product  ORDER BY sku;"
show "Orders"    "SELECT * FROM v_order    ORDER BY order_ref;"

echo; echo "======================================================================"
echo "  TEMPORAL JOINS  (no foreign keys: who + what + when)"
echo "======================================================================"
show "LAST BEFORE: each order against the profile as it was when placed" \
  "SELECT * FROM v_order_at_purchase ORDER BY order_ref;"
show "Order ownership, each row read against its own moment" \
  "SELECT * FROM v_order_ownership ORDER BY order_ref, recorded_at;"
show "FIRST EVER / FIRST AFTER: the customer journey" \
  "SELECT * FROM v_customer_journey ORDER BY customer_ref;"
