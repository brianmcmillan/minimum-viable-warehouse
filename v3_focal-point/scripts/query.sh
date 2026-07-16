#!/usr/bin/env bash
# Pretty-print the business-facing (reconstructed) views + a few of the
# framework's signature queries. Read-only.
source "$(dirname "$0")/lib.sh"
show() { echo; echo "### $1"; shift; sql_table "$1"; }

echo "======================================================================"
echo "  RECONSTRUCTED BUSINESS VIEWS  (generic rows + metadata = meaning)"
echo "======================================================================"
show "Customers"        "SELECT * FROM v_customer ORDER BY customer_key;"
show "Products"         "SELECT * FROM v_product  ORDER BY product_key;"
show "Orders"           "SELECT * FROM v_order    ORDER BY order_key;"

echo; echo "======================================================================"
echo "  SELF-DESCRIBING: every current fact decoded via its semantic key"
echo "======================================================================"
show "All facts (v_all_facts)" \
  "SELECT entity_id, entity_key, context_name, type_key,
          val_str, val_num, uom, sta_tmstp
   FROM v_all_facts ORDER BY entity_id, entity_key, type_key;"

echo; echo "======================================================================"
echo "  BI-TEMPORAL HISTORY: full timeline of ORDER_STATUS"
echo "======================================================================"
show "Order status history" "SELECT * FROM v_order_status_history;"

echo; echo "======================================================================"
echo "  OPERATIONAL LINEAGE: which pipeline wrote each order fact"
echo "======================================================================"
show "Lineage" "SELECT * FROM v_lineage ORDER BY entity_key, context_name, eff_tmstp;"
