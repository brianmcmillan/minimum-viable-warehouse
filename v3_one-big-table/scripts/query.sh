#!/usr/bin/env bash
# Pretty-print the latest tables + the pattern's signature exhibits.
source "$(dirname "$0")/lib.sh"
show()  { echo; echo "### $1"; shift; sql_table "$1"; }
ashow() { echo; echo "### $1"; shift; asql_table "$1"; }

echo "======================================================================"
echo "  LATEST TABLES  (full-refresh recomputation over the log)"
echo "======================================================================"
show "Customers" "SELECT * FROM v_customer ORDER BY customer_ref;"
show "Products"  "SELECT * FROM v_product  ORDER BY sku;"
show "Orders"    "SELECT * FROM v_order    ORDER BY order_ref;"

echo; echo "======================================================================"
echo "  THE ONE BIG TABLE: order-line grain, everything denormalized"
echo "======================================================================"
show "obt_order_wide" "SELECT * FROM obt_order_wide ORDER BY order_ref, sku;"

# History reads TEMP views over the log: attach the archive, load the
# view file, query. Nothing is copied into build/obt.db.
hshow() { echo; echo "### $1"; shift
  "$SQLITE" -cmd "ATTACH DATABASE '$(sql_quote "$ARCHIVE_DB")' AS arch" \
            -cmd ".read '$ROOT_DIR/schema/03_log_views.sql'" -header -column "$DB" "$1"; }

echo; echo "======================================================================"
echo "  HISTORY = TEMP VIEWS OVER THE LOG (schema/03_log_views.sql):"
echo "  the LAG diff is written once, in the views, not by every consumer"
echo "======================================================================"
hshow "Customer versions (a row only where a value changed)" \
 "SELECT customer_id, full_name, email_addr, valid_from, valid_to
  FROM v_customer_version ORDER BY customer_id, valid_from;"
hshow "Customers the latest table no longer holds" \
 "SELECT customer_id, went_at FROM v_customer_gone ORDER BY customer_id;"
hshow "Each order's first owner, as at that delivery" \
 "SELECT order_ref, customer_ref, full_name, email_addr, first_seen
  FROM v_order_first_owner ORDER BY order_ref;"

echo; echo "======================================================================"
echo "  STORAGE, STATED PLAINLY: no NOCHANGE suppression -- FULL feeds"
echo "  re-store the whole snapshot every delivery"
echo "======================================================================"
ashow "Archived rows per feed" \
 "SELECT feed, COUNT(DISTINCT file_id) AS deliveries, COUNT(*) AS raw_rows
  FROM (SELECT 'CRM.CUSTOMER' feed, file_id FROM arch.hist_customer
        UNION ALL SELECT 'PIM.PRODUCT',   file_id FROM arch.hist_product
        UNION ALL SELECT 'OMS.ORDER',     file_id FROM arch.hist_order
        UNION ALL SELECT 'OMS.ORDER_LINE',file_id FROM arch.hist_order_line)
  GROUP BY feed ORDER BY raw_rows DESC;"
