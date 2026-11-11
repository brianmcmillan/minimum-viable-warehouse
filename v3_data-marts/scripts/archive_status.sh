#!/usr/bin/env bash
# Report on the archive (raw layer). Read-only: there is no prune,
# and no code in this project deletes an archived row -- the append-only
# triggers in schema/02_archive.sql have no unlock path.
source "$(dirname "$0")/lib.sh"

echo "======================================================================"
echo "  ARCHIVE  $ARCHIVE_DB"
echo "======================================================================"

if [ ! -f "$ARCHIVE_DB" ]; then
  echo "  (no archive yet -- run a delivery, or ./scripts/init_db.sh)"; exit 0
fi

size="$(wc -c < "$ARCHIVE_DB" | tr -d ' ')"
echo "  file size          : $size bytes"
echo "  deliveries         : $(asql_scalar 'SELECT COUNT(*) FROM arch.loaded_files;')"
echo "  oldest delivery    : $(asql_scalar 'SELECT COALESCE(MIN(batch_ts),"-") FROM arch.loaded_files;')"
echo "  newest delivery    : $(asql_scalar 'SELECT COALESCE(MAX(batch_ts),"-") FROM arch.loaded_files;')"

incomplete="$(asql_scalar "SELECT COUNT(*) FROM arch.loaded_files WHERE status<>'COMPLETE';")"
if [ "$incomplete" -gt 0 ]; then
  echo
  echo "  !! $incomplete delivery(ies) archived but never applied (status<>COMPLETE)."
  echo "     They will be re-applied by rebuild.sh; re-running load_feed.sh with"
  echo "     the same file_id will retry rather than skip them."
fi

echo
echo "### Deliveries"
asql_table "SELECT load_seq, file_id, batch_ts, status, row_count
            FROM arch.loaded_files ORDER BY load_seq;"

echo
echo "### Archived rows per feed  (FULL feeds dominate growth)"
asql_table "SELECT feed, COUNT(DISTINCT file_id) AS deliveries, COUNT(*) AS raw_rows,
                   COUNT(*)/COUNT(DISTINCT file_id) AS rows_per_delivery
            FROM (
              SELECT 'CRM.CUSTOMER'   feed, file_id FROM arch.hist_customer
              UNION ALL SELECT 'PIM.PRODUCT',   file_id FROM arch.hist_product
              UNION ALL SELECT 'OMS.ORDER',     file_id FROM arch.hist_order
              UNION ALL SELECT 'OMS.ORDER_LINE',file_id FROM arch.hist_order_line)
            GROUP BY feed ORDER BY raw_rows DESC;"
