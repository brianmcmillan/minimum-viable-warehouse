#!/usr/bin/env bash
# ---------------------------------------------------------------------
# APPLY one delivery that is already sitting in source_landing_stage.
#   usage: BATCH_TS=<ts> apply_delivery.sh
#
# This is the ONE path from staged rows to the warehouse, shared by both
# callers:
#
#   load_feed.sh  -- stages a delivery file, archives it, then calls this
#   rebuild.sh    -- restores a delivery from the archive, then calls this
#
# They must share it. If replay went through its own code, a green rebuild
# test would prove only that the replay code works, not that it reproduces
# what ingest actually did.
#
# What it does, per feed carried by the delivery:
#   * per-feed replace: the delivery's feeds replace their rows in
#     source_landing (landing holds the CURRENT delivery per feed).
#   * recency dedup: if the delivery repeats an attribute for a key, the
#     newest by extract_ts wins (not MAX(value)). Ties break on rowid, so
#     the physical order of source_landing_stage is significant -- see
#     seq_nbr in schema/05_archive.sql.
# Then it runs the strategy-aware loaders.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

[ "$(sql_scalar "SELECT COUNT(*) FROM source_landing_stage;")" -gt 0 ] || {
  echo "FATAL: apply_delivery.sh called with an empty source_landing_stage" >&2; exit 1; }

# For each feed in the delivery: replace its landing rows (recency-deduped).
sql_run "SELECT DISTINCT source_system||'|'||source_entity FROM source_landing_stage;" |
while IFS='|' read -r ss se; do
  q_ss="$(sql_quote "$ss")"; q_se="$(sql_quote "$se")"
  mode="$(sql_scalar "SELECT COALESCE(MAX(load_mode),
             (SELECT ingestion_strategy FROM meta_source_feed
              WHERE source_system='$q_ss' AND source_entity='$q_se'))
           FROM source_landing_stage WHERE source_system='$q_ss' AND source_entity='$q_se';")"
  q_mode="$(sql_quote "$mode")"
  sql_run "
    DELETE FROM source_landing WHERE source_system='$q_ss' AND source_entity='$q_se';
    INSERT INTO source_landing(source_system,source_entity,business_key,attribute_name,
                               value_str,value_num,value_ts,extract_ts,op,load_mode)
    SELECT source_system,source_entity,business_key,attribute_name,
           value_str,value_num,value_ts,extract_ts,op,COALESCE(load_mode,'$q_mode')
    FROM (SELECT *, ROW_NUMBER() OVER (
            PARTITION BY source_system,source_entity,business_key,attribute_name
            ORDER BY extract_ts DESC, rowid DESC) rn
          FROM source_landing_stage
          WHERE source_system='$q_ss' AND source_entity='$q_se') WHERE rn=1;"
  printf "    feed %-14s mode=%s\n" "$ss.$se" "$mode"
done

# source_landing_stage still holds exactly this delivery's rows, and stays
# untouched until the next delivery clears it. That is the loaders' scope:
# each one processes only the feeds this delivery carried, and leaves every
# other feed's landing rows alone.
"$(dirname "$0")/load_keys.sh"
"$(dirname "$0")/load_desc.sh"
"$(dirname "$0")/load_rel.sh"
