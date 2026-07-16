#!/usr/bin/env bash
# ---------------------------------------------------------------------
# REBUILD the derived warehouse from the raw layer.
#   usage: rebuild.sh
#
# Drops $DB entirely and replays every archived delivery back through the
# same code path that ingested it (apply_delivery.sh). Nothing is carried
# over: identifiers, surrogate keys, descriptors, relationships and
# lineage are all regenerated.
#
# Surrogate keys come back IDENTICAL, and that is not luck. Keys are
# allocated MAX(key)+ROW_NUMBER() OVER (ORDER BY idfr), so replaying the
# same deliveries in the same order against the same prior state yields
# the same assignment. Two ordering guarantees hold it up:
#
#   * deliveries replay in load_seq order -- ingest order. Replay D4 before
#     D0 and C003 becomes key 1001 instead of 1003.
#   * a delivery's rows are restored to source_landing_stage in seq_nbr
#     order, because the recency-dedup tiebreak in apply_delivery.sh reads
#     the staged rowid.
#
# This is what "the derived warehouse is disposable" actually means, and
# it is only true while the archive is COMPLETE. Prune one delivery and
# keys start moving. See INCREMENTAL.md.
#
# Use it after fixing a loader bug, or after changing a business rule in
# meta_value_map: the raw source values were never overwritten, so the
# rule is re-derived from scratch.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

n_deliv="$(sql_int "$(asql_scalar "SELECT COUNT(*) FROM arch.loaded_files;")")"
[ "$n_deliv" -gt 0 ] || {
  echo "FATAL: archive $ARCHIVE_DB holds no deliveries -- nothing to rebuild from." >&2
  exit 1; }

n_rows="$(asql_scalar "SELECT COUNT(*) FROM arch.source_landing_history;")"
echo "======================================================================"
echo "  REBUILD from $ARCHIVE_DB"
echo "  $n_deliv delivery(ies), $n_rows archived raw row(s)"
echo "======================================================================"

"$(dirname "$0")/init_db.sh"

# Replay in ingest order -- the guarantee the whole rebuild rests on.
# batch_ts contains spaces but never a '|', so the project's usual
# pipe-joined read is safe here.
asql_run "SELECT file_id||'|'||batch_ts FROM arch.loaded_files ORDER BY load_seq;" |
while IFS='|' read -r fid bts; do
  q_fid="$(sql_quote "$fid")"
  echo "############################################################"
  echo "# REPLAY: id=$fid   (ts=$bts)"
  echo "############################################################"

  # Restore the delivery exactly as it was staged: same rows, same order.
  # The ORDER BY assigns stage rowids 1..N in seq_nbr order (SQLite honours
  # ORDER BY for rowid assignment in INSERT..SELECT), which the dedup
  # tiebreak depends on.
  adb "DELETE FROM source_landing_stage;
       INSERT INTO source_landing_stage(source_system,source_entity,business_key,
                                        attribute_name,value_str,value_num,value_ts,
                                        extract_ts,op,load_mode)
       SELECT source_system,source_entity,business_key,attribute_name,
              value_str,value_num,value_ts,extract_ts,op,load_mode
       FROM arch.source_landing_history
       WHERE file_id='$q_fid'
       ORDER BY seq_nbr;"

  BATCH_TS="$bts" "$(dirname "$0")/apply_delivery.sh"
done

echo "==> Rebuild complete: $n_deliv delivery(ies) replayed."
