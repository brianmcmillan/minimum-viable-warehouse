#!/usr/bin/env bash
# ---------------------------------------------------------------------
# DESCRIPTOR LOADER (strategy-aware) -- bi-temporal delta from the narrow
# feed, with SAFE delete semantics:
#
#   NEW / CHANGE / NOCHANGE   -- always, from UPSERT rows (recency-deduped)
#   DEL from tombstone        -- always, for keys delivered with op='DELETE'
#   DEL from absence          -- ONLY when the delivery's mode is FULL
#
# So an INCREMENTAL (windowed) delivery can never delete a key just
# because it wasn't in the window. That is the whole point of this variant.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Loading descriptors  (bi-temporal delta, batch_ts=$BATCH_TS)"
q_bts="$(sql_quote "$BATCH_TS")"

# Only the feeds this delivery actually carries (source_landing_stage holds
# exactly the current delivery while the loaders run). Feeds absent from the
# delivery keep their prior state; reprocessing their stale landing rows was
# a no-op only by accident of the NOCHANGE branch.
sql_run "SELECT DISTINCT m.entity_id, m.type_key, m.source_system, m.source_entity
                 FROM meta_source_map m
                 WHERE m.role='DESC' AND EXISTS (
                   SELECT 1 FROM source_landing_stage s
                   WHERE s.source_system=m.source_system AND s.source_entity=m.source_entity)
                 ORDER BY m.entity_id, m.type_key;" |
while IFS='|' read -r entity tk ss se; do
  q_entity="$(sql_quote "$entity")"; q_ss="$(sql_quote "$ss")"; q_se="$(sql_quote "$se")"
  tk="$(sql_int "$tk")"
  key_col="$(sql_ident "$(sql_scalar "SELECT key_col FROM meta_entity WHERE entity_id='$q_entity';")")"
  ctx="$(sql_scalar "SELECT context_name FROM meta_atomic_context WHERE type_key=$tk;")"
  le="$(printf '%s' "$entity" | tr 'A-Z' 'a-z')"
  desc_tbl="$(sql_ident "${le}_desc")"; idfr_tbl="$(sql_ident "${le}_idfr")"
  idfr_col="$(sql_ident "${le}_idfr")"; dk="$tk"

  # Effective mode for this feed (delivery override, else declared default).
  mode="$(sql_scalar "SELECT COALESCE(
             (SELECT load_mode FROM source_landing
              WHERE source_system='$q_ss' AND source_entity='$q_se' AND load_mode IS NOT NULL LIMIT 1),
             (SELECT ingestion_strategy FROM meta_source_feed
              WHERE source_system='$q_ss' AND source_entity='$q_se'), 'INCREMENTAL');")"

  # attribute + default per physical column
  a_VAL_STR=''; d_VAL_STR=''; a_VAL_NUM=''; d_VAL_NUM=''
  a_UOM='';     d_UOM='';     a_STA='';     d_STA=''; a_END=''; d_END=''
  while IFS='|' read -r phys attr dflt; do
    case "$phys" in
      VAL_STR)   a_VAL_STR="$attr"; d_VAL_STR="$dflt";;
      VAL_NUM)   a_VAL_NUM="$attr"; d_VAL_NUM="$dflt";;
      UOM)       a_UOM="$attr";     d_UOM="$dflt";;
      STA_TMSTP) a_STA="$attr";     d_STA="$dflt";;
      END_TMSTP) a_END="$attr";     d_END="$dflt";;
    esac
  done <<EOF
$(sql_run "SELECT phys_column||'|'||COALESCE(source_attribute,'')||'|'||COALESCE(default_value,'')
                   FROM meta_source_map WHERE role='DESC' AND type_key=$tk
                     AND source_system='$q_ss' AND source_entity='$q_se';")
EOF

  slot() { [ -n "$2" ] && echo "MAX(CASE WHEN attribute_name='$(sql_quote "$2")' THEN $1 END)" || echo "NULL"; }
  gs="$(slot value_str "$a_VAL_STR")"; gn="$(slot value_num "$a_VAL_NUM")"
  gu="$(slot value_str "$a_UOM")";     gsta="$(slot value_ts "$a_STA")"; gend="$(slot value_ts "$a_END")"
  [ -n "$d_VAL_STR" ] && e_valstr="COALESCE(gs,'$(sql_quote "$d_VAL_STR")')" || e_valstr="gs"
  [ -n "$d_VAL_NUM" ] && e_valnum="COALESCE(gn,'$(sql_quote "$d_VAL_NUM")')" || e_valnum="gn"
  [ -n "$d_UOM" ]     && e_uom="COALESCE(gu,'$(sql_quote "$d_UOM")')"       || e_uom="gu"
  [ -n "$d_STA" ]     && e_sta="COALESCE(gsta,'$(sql_quote "$d_STA")')"     || e_sta="gsta"
  [ -n "$d_END" ]     && e_end="COALESCE(gend,'$(sql_quote "$d_END")')"     || e_end="gend"
  if [ "$(sql_scalar "SELECT COUNT(*) FROM meta_value_map WHERE type_key=$tk;")" -gt 0 ]; then
    whens="$(sql_run "SELECT ' WHEN '''||source_value||''' THEN '''||target_value||''''
                              FROM meta_value_map WHERE type_key=$tk;" | tr -d '\n')"
    e_valstr="CASE $e_valstr$whens ELSE $e_valstr END"
  fi

  # Absence-based delete only for FULL deliveries.
  if [ "$mode" = "FULL" ]; then
    ABS_CTE=",del_abs AS (
      SELECT t.ek, t.sta_tmstp,t.end_tmstp,t.val_str,t.val_num,t.uom,'DEL' AS flag
      FROM tgt t LEFT JOIN src s ON s.ek=t.ek
                 LEFT JOIN delkeys d ON d.ek=t.ek
      WHERE s.ek IS NULL AND d.ek IS NULL )"
    ABS_UNION="UNION ALL SELECT * FROM del_abs"
  else
    ABS_CTE=""; ABS_UNION=""
  fi

  tmp="$(mktemp)"
  cat > "$tmp" <<SQL
WITH grain AS (
  SELECT business_key AS idfr,
         $gs AS gs, $gn AS gn, $gu AS gu, $gsta AS gsta, $gend AS gend
  FROM source_landing
  WHERE source_system='$q_ss' AND source_entity='$q_se' AND op='UPSERT'
  GROUP BY business_key
),
reader AS (
  SELECT idfr, $e_sta AS sta_tmstp, $e_end AS end_tmstp,
         $e_valstr AS val_str, $e_valnum AS val_num, $e_uom AS uom
  FROM grain
),
src AS (
  SELECT i.$key_col AS ek, r.sta_tmstp, r.end_tmstp, r.val_str, r.val_num, r.uom
  FROM reader r JOIN $idfr_tbl i ON r.idfr = i.$idfr_col AND i.row_st='Y'
),
tgt AS (
  SELECT ek, sta_tmstp, end_tmstp, val_str, val_num, uom FROM (
    SELECT $key_col AS ek, sta_tmstp, end_tmstp, val_str, val_num, uom, row_st,
           ROW_NUMBER() OVER (PARTITION BY $key_col
                              ORDER BY eff_tmstp DESC, ver_tmstp DESC) AS rn
    FROM $desc_tbl WHERE type_key=$tk AND data_key=$dk
  ) WHERE rn=1 AND row_st='Y'
),
delkeys AS (
  SELECT DISTINCT i.$key_col AS ek
  FROM source_landing sl
  JOIN $idfr_tbl i ON i.$idfr_col = sl.business_key AND i.row_st='Y'
  WHERE sl.source_system='$q_ss' AND sl.source_entity='$q_se' AND sl.op='DELETE'
),
upsert_delta AS (
  SELECT s.ek, s.sta_tmstp, s.end_tmstp, s.val_str, s.val_num, s.uom,
         CASE WHEN t.ek IS NULL THEN 'NEW'
              WHEN s.val_str IS t.val_str AND s.val_num IS t.val_num
               AND s.uom IS t.uom AND s.sta_tmstp IS t.sta_tmstp
               AND s.end_tmstp IS t.end_tmstp THEN 'NOCHANGE'
              ELSE 'CHANGE' END AS flag
  FROM src s LEFT JOIN tgt t ON s.ek=t.ek
),
del_tomb AS (
  SELECT t.ek, t.sta_tmstp,t.end_tmstp,t.val_str,t.val_num,t.uom,'DEL' AS flag
  FROM tgt t JOIN delkeys d ON d.ek=t.ek
)$ABS_CTE
INSERT INTO $desc_tbl($key_col, type_key, eff_tmstp, ver_tmstp, seq_nbr, row_st,
                      sta_tmstp, end_tmstp, val_str, val_num, uom,
                      data_key, inst_key, inst_row_key, popln_tmstp)
SELECT ek, $tk, '$q_bts', '$q_bts', 0,
       CASE WHEN flag='DEL' THEN 'N' ELSE 'Y' END,
       sta_tmstp, end_tmstp, val_str, val_num, uom,
       $dk, __INST__, 1, '$q_bts'
FROM (
  SELECT * FROM upsert_delta WHERE flag IN ('NEW','CHANGE')
  UNION ALL SELECT * FROM del_tomb
  $ABS_UNION
) x;
SQL
  inst="$(sql_int "$(log_procinst "DESC:$entity:$ctx:$ss.$se:$mode" "$tmp")")"
  sed "s/__INST__/$inst/g" "$tmp" | sql
  n="$(sql_scalar "SELECT COUNT(*) FROM $desc_tbl WHERE inst_key=$inst;")"
  printf "    %-9s %-16s [%-11s]: %s row(s)\n" "$entity" "$ctx" "$mode" "$n"
  rm -f "$tmp"
done
