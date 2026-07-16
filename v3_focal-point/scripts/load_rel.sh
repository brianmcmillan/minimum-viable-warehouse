#!/usr/bin/env bash
# ---------------------------------------------------------------------
# RELATIONSHIP LOADER (strategy-aware). Same safe-delete rule as
# descriptors: absence deletes a link only for a FULL delivery; for
# INCREMENTAL, a removed link must arrive as an op='DELETE' tombstone row.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Loading relationships (bi-temporal delta, batch_ts=$BATCH_TS)"
q_bts="$(sql_quote "$BATCH_TS")"
# Only relationships whose driving feed is present in this delivery
# (source_landing_stage holds exactly the current delivery here).
sql_run "SELECT r.type_key, r.rel_name, r.source_entity, r.target_entity, r.x_table,
                        m.source_system, m.source_entity, m.source_key_attr, m.target_key_attr
                 FROM meta_relationship r JOIN meta_rel_map m ON r.type_key=m.type_key
                 WHERE EXISTS (
                   SELECT 1 FROM source_landing_stage s
                   WHERE s.source_system=m.source_system AND s.source_entity=m.source_entity)
                 ORDER BY r.type_key;" |
while IFS='|' read -r tk rel se te xt ss feed sattr tattr; do
  tk="$(sql_int "$tk")"
  q_se="$(sql_quote "$se")"; q_te="$(sql_quote "$te")"
  q_ss="$(sql_quote "$ss")"; q_feed="$(sql_quote "$feed")"
  q_sattr="$(sql_quote "$sattr")"; q_tattr="$(sql_quote "$tattr")"
  xt="$(sql_ident "$xt")"
  s_key="$(sql_ident "$(sql_scalar "SELECT key_col FROM meta_entity WHERE entity_id='$q_se';")")"
  t_key="$(sql_ident "$(sql_scalar "SELECT key_col FROM meta_entity WHERE entity_id='$q_te';")")"
  s_le="$(printf '%s' "$se" | tr 'A-Z' 'a-z')"; t_le="$(printf '%s' "$te" | tr 'A-Z' 'a-z')"
  s_idfr="$(sql_ident "${s_le}_idfr")"; t_idfr="$(sql_ident "${t_le}_idfr")"
  s_idfrc="$(sql_ident "${s_le}_idfr")"; t_idfrc="$(sql_ident "${t_le}_idfr")"; dk="$tk"

  mode="$(sql_scalar "SELECT COALESCE(
             (SELECT load_mode FROM source_landing
              WHERE source_system='$q_ss' AND source_entity='$q_feed' AND load_mode IS NOT NULL LIMIT 1),
             (SELECT ingestion_strategy FROM meta_source_feed
              WHERE source_system='$q_ss' AND source_entity='$q_feed'), 'INCREMENTAL');")"
  if [ "$mode" = "FULL" ]; then
    ABS_CTE=",del_abs AS (
      SELECT t.sk, t.tk, 'DEL' AS flag
      FROM tgt t LEFT JOIN src s ON s.sk=t.sk AND s.tk=t.tk
                 LEFT JOIN delpairs d ON d.sk=t.sk AND d.tk=t.tk
      WHERE s.sk IS NULL AND d.sk IS NULL )"
    ABS_UNION="UNION ALL SELECT * FROM del_abs"
  else ABS_CTE=""; ABS_UNION=""; fi

  tmp="$(mktemp)"
  cat > "$tmp" <<SQL
WITH up AS (
  SELECT MAX(CASE WHEN attribute_name='$q_sattr' THEN value_str END) AS s_ref,
         MAX(CASE WHEN attribute_name='$q_tattr' THEN value_str END) AS t_ref
  FROM source_landing WHERE source_system='$q_ss' AND source_entity='$q_feed' AND op='UPSERT'
  GROUP BY business_key
),
dl AS (
  SELECT MAX(CASE WHEN attribute_name='$q_sattr' THEN value_str END) AS s_ref,
         MAX(CASE WHEN attribute_name='$q_tattr' THEN value_str END) AS t_ref
  FROM source_landing WHERE source_system='$q_ss' AND source_entity='$q_feed' AND op='DELETE'
  GROUP BY business_key
),
src AS (
  SELECT si.$s_key AS sk, ti.$t_key AS tk FROM up p
  JOIN $s_idfr si ON p.s_ref=si.$s_idfrc AND si.row_st='Y'
  JOIN $t_idfr ti ON p.t_ref=ti.$t_idfrc AND ti.row_st='Y'
),
delpairs AS (
  SELECT si.$s_key AS sk, ti.$t_key AS tk FROM dl p
  JOIN $s_idfr si ON p.s_ref=si.$s_idfrc AND si.row_st='Y'
  JOIN $t_idfr ti ON p.t_ref=ti.$t_idfrc AND ti.row_st='Y'
),
tgt AS (
  SELECT sk, tk FROM (
    SELECT $s_key AS sk, $t_key AS tk, row_st,
           ROW_NUMBER() OVER (PARTITION BY $s_key,$t_key
                              ORDER BY eff_tmstp DESC, ver_tmstp DESC) AS rn
    FROM $xt WHERE type_key=$tk AND data_key=$dk
  ) WHERE rn=1 AND row_st='Y'
),
new_delta AS (
  SELECT s.sk, s.tk, 'NEW' AS flag
  FROM src s LEFT JOIN tgt t ON s.sk=t.sk AND s.tk=t.tk WHERE t.sk IS NULL
),
del_tomb AS (
  SELECT t.sk, t.tk, 'DEL' AS flag
  FROM tgt t JOIN delpairs d ON d.sk=t.sk AND d.tk=t.tk
)$ABS_CTE
INSERT INTO $xt($s_key, $t_key, type_key, eff_tmstp, ver_tmstp, row_st,
                data_key, inst_key, inst_row_key, popln_tmstp)
SELECT sk, tk, $tk, '$q_bts', '$q_bts',
       CASE WHEN flag='DEL' THEN 'N' ELSE 'Y' END,
       $dk, __INST__, 1, '$q_bts'
FROM (
  SELECT * FROM new_delta
  UNION ALL SELECT * FROM del_tomb
  $ABS_UNION
) x;
SQL
  inst="$(sql_int "$(log_procinst "REL:$rel:$ss.$feed:$mode" "$tmp")")"
  sed "s/__INST__/$inst/g" "$tmp" | sql
  n="$(sql_scalar "SELECT COUNT(*) FROM $xt WHERE inst_key=$inst;")"
  printf "    %-10s (%s->%s) [%-11s]: %s change(s)\n" "$rel" "$se" "$te" "$mode" "$n"
  rm -f "$tmp"
done
