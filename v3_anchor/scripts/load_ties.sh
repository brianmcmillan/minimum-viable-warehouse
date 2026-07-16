#!/usr/bin/env bash
# ---------------------------------------------------------------------
# TIE LOADER -- relationships, metadata-driven.
#
# A HISTORIZED tie is latest-per-driving-role: delivering a pair that
# differs from the driving role's current pairing appends a new row,
# which supersedes the old one by ChangedAt -- no update, no end date
# (computed on the way out via LEAD, cf. v_order_customer_history).
# This is Anchor's native answer to the re-pointed order, equivalent to
# the DV demo's effectivity satellite.
#
# A STATIC tie is a set of immutable pairs: insert when absent.
# Tie deletes are out of scope, as in the sibling demos.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
echo "==> Loading ties (batch_ts=$BATCH_TS)"
q_bts="$(sql_quote "$BATCH_TS")"

sql_run "SELECT t.tie_table||'|'||t.historized||'|'||t.source_system||'|'||t.source_entity
                ||'|'||t.src_attribute||'|'||t.src_id_col||'|'||sa.ref_table||'|'||sa.ref_col
                ||'|'||t.tgt_attribute||'|'||t.tgt_id_col||'|'||ta.ref_table||'|'||ta.ref_col
         FROM meta_tie_map t
         JOIN meta_anchor_map sa ON sa.anchor_mn = t.src_anchor_mn
         JOIN meta_anchor_map ta ON ta.anchor_mn = t.tgt_anchor_mn
         ORDER BY t.tie_table;" |
while IFS='|' read -r ttab hist ss se sattr sidc srtab srcol tattr tidc trtab trcol; do
  [ "$(feed_present "$ss" "$se")" -gt 0 ] || continue
  ttab="$(sql_ident "$ttab")"
  sidc="$(sql_ident "$sidc")"; srtab="$(sql_ident "$srtab")"; srcol="$(sql_ident "$srcol")"
  tidc="$(sql_ident "$tidc")"; trtab="$(sql_ident "$trtab")"; trcol="$(sql_ident "$trcol")"
  q_ss="$(sql_quote "$ss")"; q_se="$(sql_quote "$se")"
  q_sattr="$(sql_quote "$sattr")"; q_tattr="$(sql_quote "$tattr")"

  PAIRS="SELECT sr.$sidc AS sid, tr.$tidc AS tid
         FROM (SELECT MAX(CASE WHEN attribute_name='$q_sattr' THEN value_str END) AS s_ref,
                      MAX(CASE WHEN attribute_name='$q_tattr' THEN value_str END) AS t_ref
               FROM source_landing
               WHERE source_system='$q_ss' AND source_entity='$q_se' AND op='UPSERT'
               GROUP BY business_key) p
         JOIN $srtab sr ON sr.$srcol = p.s_ref
         JOIN $trtab tr ON tr.$trcol = p.t_ref"

  if [ "$hist" = "1" ]; then
    sql_run "
      INSERT INTO $ttab($sidc, $tidc, ChangedAt, Metadata_LDTS)
      SELECT s.sid, s.tid, '$q_bts', '$q_bts'
      FROM ($PAIRS) s
      LEFT JOIN (SELECT $sidc AS sid, $tidc AS tid, ROW_NUMBER() OVER
                   (PARTITION BY $sidc ORDER BY ChangedAt DESC) rn FROM $ttab) c
             ON c.sid = s.sid AND c.rn = 1
      WHERE c.sid IS NULL OR c.tid <> s.tid;"
  else
    sql_run "
      INSERT INTO $ttab($sidc, $tidc, Metadata_LDTS)
      SELECT s.sid, s.tid, '$q_bts'
      FROM ($PAIRS) s
      WHERE NOT EXISTS (SELECT 1 FROM $ttab x
                        WHERE x.$sidc = s.sid AND x.$tidc = s.tid);"
  fi
  n="$(sql_scalar "SELECT COUNT(*) FROM $ttab WHERE Metadata_LDTS='$q_bts';")"
  printf "    %-18s [%s]: %s change(s)\n" "$ttab" "$([ "$hist" = 1 ] && echo historized || echo static)" "$n"
done
