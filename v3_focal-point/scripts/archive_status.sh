#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Report on the raw layer. Read-only: there is no prune, and no code in
# this project deletes an archived row -- the append-only triggers in
# schema/05_archive.sql have no unlock path.
#
# The per-feed breakdown is the number worth watching. FULL feeds
# re-archive their entire snapshot on every delivery, changed or not,
# because absence-means-delete can only be replayed if the full snapshot
# was captured. That is correct, and it is also where the growth is.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

echo "======================================================================"
echo "  RAW LAYER  $ARCHIVE_DB"
echo "======================================================================"

if [ ! -f "$ARCHIVE_DB" ]; then
  echo "  (no archive yet -- run a delivery, or ./scripts/init_db.sh)"; exit 0
fi

size="$(wc -c < "$ARCHIVE_DB" | tr -d ' ')"
echo "  file size          : $size bytes"
echo "  deliveries         : $(asql_scalar 'SELECT COUNT(*) FROM arch.loaded_files;')"
echo "  archived raw rows  : $(asql_scalar 'SELECT COUNT(*) FROM arch.source_landing_history;')"
echo "  oldest delivery    : $(asql_scalar 'SELECT COALESCE(MIN(batch_ts),"-") FROM arch.loaded_files;')"
echo "  newest delivery    : $(asql_scalar 'SELECT COALESCE(MAX(batch_ts),"-") FROM arch.loaded_files;')"

incomplete="$(asql_scalar "SELECT COUNT(*) FROM arch.loaded_files WHERE status<>'COMPLETE';")"
if [ "$incomplete" -gt 0 ]; then
  echo
  echo "  !! $incomplete delivery(ies) archived but never applied (status<>COMPLETE)."
  echo "     They will be re-applied by rebuild.sh, and re-running load_feed.sh"
  echo "     with the same file_id will retry rather than skip them."
  asql_table "SELECT file_id, load_seq, batch_ts, status, row_count
              FROM arch.loaded_files WHERE status<>'COMPLETE' ORDER BY load_seq;"
fi

echo
echo "### Deliveries"
asql_table "SELECT load_seq, file_id, batch_ts, status, row_count
            FROM arch.loaded_files ORDER BY load_seq;"

echo
echo "### Archived rows per feed  (FULL feeds dominate growth)"
asql_table "SELECT h.source_system || '.' || h.source_entity AS feed,
                   COALESCE(f.ingestion_strategy,'?')        AS strategy,
                   COUNT(DISTINCT h.file_id)                 AS deliveries,
                   COUNT(*)                                  AS raw_rows,
                   COUNT(*) / COUNT(DISTINCT h.file_id)      AS rows_per_delivery
            FROM arch.source_landing_history h
            LEFT JOIN main.meta_source_feed f
                   ON f.source_system = h.source_system
                  AND f.source_entity = h.source_entity
            GROUP BY 1, 2
            ORDER BY raw_rows DESC;"
