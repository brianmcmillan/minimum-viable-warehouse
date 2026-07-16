#!/usr/bin/env bash
# Report on the Persistent Staging Area. Read-only: there is no prune,
# and no code in this project deletes an archived row -- the append-only
# triggers in schema/02_psa.sql have no unlock path.
source "$(dirname "$0")/lib.sh"

echo "======================================================================"
echo "  PERSISTENT STAGING AREA  $PSA_DB"
echo "======================================================================"

if [ ! -f "$PSA_DB" ]; then
  echo "  (no PSA yet -- run a delivery, or ./scripts/init_db.sh)"; exit 0
fi

size="$(wc -c < "$PSA_DB" | tr -d ' ')"
echo "  file size          : $size bytes"
echo "  deliveries         : $(psql_scalar 'SELECT COUNT(*) FROM psa.loaded_files;')"
echo "  oldest delivery    : $(psql_scalar 'SELECT COALESCE(MIN(batch_ts),"-") FROM psa.loaded_files;')"
echo "  newest delivery    : $(psql_scalar 'SELECT COALESCE(MAX(batch_ts),"-") FROM psa.loaded_files;')"

incomplete="$(psql_scalar "SELECT COUNT(*) FROM psa.loaded_files WHERE status<>'COMPLETE';")"
if [ "$incomplete" -gt 0 ]; then
  echo
  echo "  !! $incomplete delivery(ies) archived but never applied (status<>COMPLETE)."
  echo "     They will be re-applied by rebuild.sh; re-running load_feed.sh with"
  echo "     the same file_id will retry rather than skip them."
fi

echo
echo "### Deliveries"
psql_table "SELECT load_seq, file_id, batch_ts, status, row_count
            FROM psa.loaded_files ORDER BY load_seq;"

echo
echo "### Archived rows per feed  (FULL feeds dominate growth)"
psql_table "SELECT feed, COUNT(DISTINCT file_id) AS deliveries, COUNT(*) AS raw_rows,
                   COUNT(*)/COUNT(DISTINCT file_id) AS rows_per_delivery
            FROM (
              SELECT 'CRM.CUSTOMER'   feed, file_id FROM psa.psa_customer
              UNION ALL SELECT 'PIM.PRODUCT',   file_id FROM psa.psa_product
              UNION ALL SELECT 'OMS.ORDER',     file_id FROM psa.psa_order
              UNION ALL SELECT 'OMS.ORDER_LINE',file_id FROM psa.psa_order_line)
            GROUP BY feed ORDER BY raw_rows DESC;"
