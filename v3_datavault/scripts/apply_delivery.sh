#!/usr/bin/env bash
# APPLY one delivery already sitting in the stage-1 tables. The ONE path
# shared by load_feed.sh (ingest) and rebuild.sh (replay) -- a green
# rebuild must prove the real loaders. Fixed order: hubs -> sats -> links,
# then the query-assist refresh (CPIT tables and the order bridge), so
# ingest and replay leave them identical.
source "$(dirname "$0")/lib.sh"

total="$(sql_scalar "SELECT (SELECT COUNT(*) FROM stg_customer_l1)
                          + (SELECT COUNT(*) FROM stg_product_l1)
                          + (SELECT COUNT(*) FROM stg_order_l1)
                          + (SELECT COUNT(*) FROM stg_order_line_l1);")"
[ "$total" -gt 0 ] || {
  echo "FATAL: apply_delivery.sh called with an empty stage" >&2; exit 1; }

# '0', '-1' and '-2' are the vault's reserved keys (ghost, null required,
# null optional). A source that sends one as a real business key would be
# indistinguishable from them, so the delivery is refused before any
# loader runs. (The raw vault's triggers are the backstop.)
bad="$(sql_scalar "SELECT group_concat(k, ', ') FROM (
         SELECT 'CRM.CUSTOMER.customer_id='||TRIM(customer_id) k FROM stg_customer_l1
          WHERE TRIM(customer_id) IN ('0','-1','-2')
         UNION ALL SELECT 'PIM.PRODUCT.sku='||TRIM(sku) FROM stg_product_l1
          WHERE TRIM(sku) IN ('0','-1','-2')
         UNION ALL SELECT 'OMS.ORDER.order_ref='||TRIM(order_ref) FROM stg_order_l1
          WHERE TRIM(order_ref) IN ('0','-1','-2')
         UNION ALL SELECT 'OMS.ORDER.customer_ref='||TRIM(customer_ref) FROM stg_order_l1
          WHERE TRIM(customer_ref) IN ('0','-1','-2')
         UNION ALL SELECT 'OMS.ORDER_LINE.order_ref='||TRIM(order_ref) FROM stg_order_line_l1
          WHERE TRIM(order_ref) IN ('0','-1','-2')
         UNION ALL SELECT 'OMS.ORDER_LINE.sku='||TRIM(sku) FROM stg_order_line_l1
          WHERE TRIM(sku) IN ('0','-1','-2'));")"
[ -z "$bad" ] || {
  echo "FATAL: delivery uses a reserved key value as a business key: $bad" >&2; exit 1; }

"$(dirname "$0")/load_hubs.sh"
"$(dirname "$0")/load_sats.sh"
"$(dirname "$0")/load_links.sh"
"$(dirname "$0")/refresh_query_assist.sh"
