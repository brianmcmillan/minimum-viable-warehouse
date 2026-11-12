#!/usr/bin/env bash
# ---------------------------------------------------------------------
# REBUILD the mart from the raw layer: init + ordered replay through
# apply_delivery.sh. Every surrogate (res_id, provider_id, res_grp_id)
# and every srcd_ts comes back identical because the archive is complete
# and three orderings hold -- load_seq across deliveries, seq_nbr within
# one, ORDER BY business key inside the inserts.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

n_deliv="$(sql_int "$(asql_scalar "SELECT COUNT(*) FROM arch.loaded_files;")")"
[ "$n_deliv" -gt 0 ] || {
  echo "FATAL: archive $ARCHIVE_DB holds no deliveries -- nothing to rebuild from." >&2
  exit 1; }

echo "======================================================================"
echo "  REBUILD from $ARCHIVE_DB  ($n_deliv delivery(ies))"
echo "======================================================================"

"$(dirname "$0")/init_db.sh"

# Only COMPLETE deliveries are replayed: a delivery that never finished
# was never part of the mart.
asql_run "SELECT file_id||'|'||batch_ts||'|'||load_seq FROM arch.loaded_files
          WHERE status='COMPLETE' ORDER BY load_seq;" |
while IFS='|' read -r fid bts seq; do
  q_fid="$(sql_quote "$fid")"
  echo "############################################################"
  echo "# REPLAY: id=$fid   (ts=$bts)"
  echo "############################################################"
  adb "DELETE FROM source_landing_stage;
       INSERT INTO source_landing_stage(source_system,source_entity,business_key,
                                        attribute_name,value_str,value_num,value_ts,
                                        extract_ts,op,load_mode)
       SELECT source_system,source_entity,business_key,attribute_name,
              value_str,value_num,value_ts,extract_ts,op,load_mode
       FROM arch.source_landing_history
       WHERE file_id='$q_fid'
       ORDER BY seq_nbr;"
  BATCH_TS="$bts" BATCH_NO="$seq" "$(dirname "$0")/apply_delivery.sh"
done

sql_run "DELETE FROM source_landing_stage;"
echo "==> Rebuild complete: $n_deliv delivery(ies) in the archive."
