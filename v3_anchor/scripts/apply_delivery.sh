#!/usr/bin/env bash
# ---------------------------------------------------------------------
# APPLY one delivery already sitting in source_landing_stage. The ONE
# path shared by load_feed.sh (ingest) and rebuild.sh (replay), as in
# every sibling demo -- a green rebuild must prove the real loaders.
#
# Per feed carried by the delivery: replace its rows in source_landing
# (landing holds the CURRENT delivery per feed), recency-deduped --
# newest per (key, attribute) by extract_ts, ties broken by rowid, so
# the physical stage order is significant (seq_nbr in the archive).
# Then the three loaders: anchors -> attributes -> ties.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"

[ "$(sql_scalar "SELECT COUNT(*) FROM source_landing_stage;")" -gt 0 ] || {
  echo "FATAL: apply_delivery.sh called with an empty source_landing_stage" >&2; exit 1; }

sql_run "SELECT DISTINCT source_system||'|'||source_entity FROM source_landing_stage;" |
while IFS='|' read -r ss se; do
  q_ss="$(sql_quote "$ss")"; q_se="$(sql_quote "$se")"
  mode="$(feed_mode "$ss" "$se")"
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

"$(dirname "$0")/load_anchors.sh"
"$(dirname "$0")/load_attributes.sh"
"$(dirname "$0")/load_ties.sh"
