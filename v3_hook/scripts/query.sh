#!/usr/bin/env bash
# Pretty-print the HOOK warehouse: the registry, the business views, and
# the signature queries. Business sections mirror the sibling demos'
# query.sh so outputs compare directly.
source "$(dirname "$0")/lib.sh"
show() { echo; echo "### $1"; shift; sql_table "$1"; }

echo "======================================================================"
echo "  THE MODEL IS A REGISTRY: concepts, key sets, and where hooks live"
echo "======================================================================"
show "Hook columns by frame" \
  "SELECT c.frame, c.hook_column, c.keyset, k.concept
   FROM hook_column c JOIN hook_keyset k USING (keyset)
   JOIN hook_frame f USING (frame) ORDER BY f.load_order, c.hook_column;"

echo; echo "======================================================================"
echo "  BUSINESS VIEWS  (current state, derived from delta frames)"
echo "======================================================================"
show "Customers" "SELECT * FROM v_customer ORDER BY customer_ref;"
show "Products"  "SELECT * FROM v_product  ORDER BY sku;"
show "Orders"    "SELECT * FROM v_order    ORDER BY order_ref;"

echo; echo "======================================================================"
echo "  A FRAME IS THE SOURCE ROW + HOOKS (raw 'P' stored, decoded on read)"
echo "======================================================================"
show "frame__oms__order" \
  "SELECT hk_order, hk_customer, status, amount, change_type, load_ts, record_source
   FROM frame__oms__order ORDER BY hk_order, load_ts;"
show "frame__crm__customer" \
  "SELECT hk_customer, full_name, email_addr, change_type, delete_basis, load_ts, record_source
   FROM frame__crm__customer ORDER BY hk_customer, load_ts;"

echo; echo "======================================================================"
echo "  HUB ON DEMAND: concept members derived from hooks across frames"
echo "======================================================================"
show "Concept members" \
  "SELECT concept, hook, first_seen, n_frames, frames
   FROM v_concept_member ORDER BY concept, hook;"

echo; echo "======================================================================"
echo "  POINT-IN-TIME: hook equality + as-of ordering (no validity windows)"
echo "======================================================================"
show "Orders as recorded" \
  "SELECT * FROM v_order_as_recorded ORDER BY order_ref, recorded_at;"
