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

echo; echo "======================================================================"
echo "  HISTORY = DIFFING THE LOG. Possible, but every question is a query"
echo "  like this one (email changes for every customer, via LAG):"
echo "======================================================================"
ashow "Email change history, computed on demand" \
 "SELECT customer_id, email_addr, batch_ts FROM (
    SELECT customer_id, email_addr, batch_ts,
           LAG(email_addr) OVER (PARTITION BY customer_id
                                 ORDER BY load_seq, extract_dt, seq_nbr) AS prev
    FROM arch.hist_customer WHERE op='UPSERT')
  WHERE prev IS NULL OR email_addr IS NOT prev
  ORDER BY customer_id, batch_ts;"

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
