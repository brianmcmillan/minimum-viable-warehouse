#!/usr/bin/env bash
# ---------------------------------------------------------------------
# ROUTE the narrow landing into the mart's staging tables.
#
#   RES feeds     -> RES_STG        one row per resource in the delivery
#                 -> RES_ALIAS_STG  the name the provider uses for it
#   METRIC attrs  -> METRIC_STG     one row per measurement
#   MEMBER feeds  -> RES_RESGRP_STG one row per group membership
#   EVENT feeds   -> CALNDR_EVENT_STG one row per calendar event
#
# The shared delete rule is applied HERE, where the delivery's mode is
# still known, and reaches the loaders as load_oper = 'D':
#   * a tombstone (op='DELETE') always deletes;
#   * a live resource absent from a FULL delivery is deleted;
#   * a resource absent from an INCREMENTAL delivery is left alone.
#
# A narrow delivery may carry only some attributes of a resource. An
# attribute that did not arrive is "no change": RES_STG.res_name falls
# back to the name the mart already holds.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
q_bts="$(sql_quote "$BATCH_TS")"
bno="$(sql_int "$BATCH_NO")"

# ---- calendar events: pivot the narrow rows into CALNDR_EVENT_STG
# ---- columns. The column list comes from meta_attribute_map, so the
# ---- router names no event column itself.
#   value_num -> CAST AS INTEGER (every numeric event column is whole)
#   value_ts  -> date()          (every timestamp event column is a date)
EV_PIVOT=""; EV_COLS=""; EV_MERGE=""
while IFS='|' read -r attr col slot; do
  [ -n "$attr" ] || continue
  col="$(sql_ident "$col")"; slot="$(sql_ident "$slot")"
  case "$slot" in
    value_num) expr="CAST(MAX(CASE WHEN c.attribute_name='$(sql_quote "$attr")' THEN c.value_num END) AS INTEGER)";;
    value_ts)  expr="date(MAX(CASE WHEN c.attribute_name='$(sql_quote "$attr")' THEN c.value_ts END))";;
    *)         expr="MAX(CASE WHEN c.attribute_name='$(sql_quote "$attr")' THEN c.value_str END)";;
  esac
  EV_PIVOT+=", $expr AS $col"
  EV_COLS+=", $col"
  case "$col" in
    group_path)       EV_MERGE+=", COALESCE(k.group_path, g.group_path)";;
    event_grp_code)   EV_MERGE+=", COALESCE(k.event_grp_code, xg.event_grp_code)";;
    inheritance_flag) EV_MERGE+=", COALESCE(k.inheritance_flag, e.inheritance_flag, 0)";;
    event_start_tm)   EV_MERGE+=", COALESCE(k.event_start_tm, e.event_start_tm, '00:00:00')";;
    *)                EV_MERGE+=", COALESCE(k.$col, e.$col)";;
  esac
done < <(sql_run "SELECT source_attribute||'|'||target_col||'|'||slot FROM meta_attribute_map
                  WHERE target_kind='EVENT_COL' ORDER BY target_col;")

sql_tx "
BEGIN;
DELETE FROM res_stg; DELETE FROM res_alias_stg; DELETE FROM res_resgrp_stg;
DELETE FROM metric_stg; DELETE FROM metric_stg2; DELETE FROM calndr_event_stg;

-- Resources named by the delivery (upserts and tombstones).
WITH k AS (
  SELECT f.res_type, c.business_key AS res_code,
         MAX(CASE WHEN c.op =  'DELETE' THEN c.extract_ts END) AS del_ts,
         MAX(CASE WHEN c.op <> 'DELETE' THEN c.extract_ts END) AS ups_ts,
         MAX(c.extract_ts) AS ext_ts,
         MAX(CASE WHEN m.target_kind='RES_COL' AND m.target_col='res_name'       THEN c.value_str END) AS res_name,
         MAX(CASE WHEN m.target_kind='RES_COL' AND m.target_col='res_short_name' THEN c.value_str END) AS res_short_name,
         MAX(CASE WHEN m.target_kind='RES_COL' AND m.target_col='res_desc'       THEN c.value_str END) AS res_desc,
         MAX(CASE WHEN m.target_kind='PARENT' THEN c.value_str END)       AS parent_alias,
         MAX(CASE WHEN m.target_kind='PARENT' THEN m.parent_res_type END) AS parent_type
  FROM $CUR c
  JOIN meta_feed_map f ON f.source_system=c.source_system AND f.source_entity=c.source_entity
                      AND f.role='RES'
  LEFT JOIN meta_attribute_map m ON m.source_system=c.source_system
                                AND m.source_entity=c.source_entity
                                AND m.source_attribute=c.attribute_name
  GROUP BY f.res_type, c.business_key),
o AS (
  SELECT k.*, CASE WHEN del_ts IS NOT NULL AND (ups_ts IS NULL OR del_ts >= ups_ts)
                   THEN 'D' ELSE 'U' END AS load_oper FROM k)
INSERT INTO res_stg(batch_no, load_oper, res_type, res_code, res_name, res_short_name,
                    parent_res_alias, parent_res_type, site_alias, support_ctr_code,
                    res_tz_code, res_status, sequence_no, srcd_ts, res_desc)
SELECT $bno, o.load_oper, o.res_type, o.res_code,
       COALESCE(o.res_name, r.res_name, o.res_code),
       COALESCE(o.res_short_name, r.res_short_name),
       o.parent_alias, o.parent_type, NULL, 'NONE', 'UTC',
       CASE o.load_oper WHEN 'D' THEN 0 ELSE 1 END,
       ROW_NUMBER() OVER (ORDER BY o.res_type, o.res_code),
       datetime(o.ext_ts),
       COALESCE(o.res_desc, r.res_desc)
FROM o LEFT JOIN res r ON r.res_type=o.res_type AND r.res_code=o.res_code;

-- >> ABSENCE means DELETE only for a FULL delivery. <<
INSERT INTO res_stg(batch_no, load_oper, res_type, res_code, res_name, res_short_name,
                    parent_res_alias, parent_res_type, site_alias, support_ctr_code,
                    res_tz_code, res_status, sequence_no, srcd_ts, res_desc)
SELECT $bno, 'D', r.res_type, r.res_code, r.res_name, r.res_short_name,
       NULL, NULL, NULL, 'NONE', 'UTC', 0,
       (SELECT COALESCE(MAX(sequence_no),0) FROM res_stg)
         + ROW_NUMBER() OVER (ORDER BY r.res_type, r.res_code),
       datetime(d.ext_ts), r.res_desc
FROM res r
JOIN meta_feed_map f ON f.res_type=r.res_type AND f.role='RES'
JOIN (SELECT source_system, source_entity,
             COALESCE(MAX(load_mode),'INCREMENTAL') AS mode, MAX(extract_ts) AS ext_ts
      FROM $CUR GROUP BY source_system, source_entity) d
  ON d.source_system=f.source_system AND d.source_entity=f.source_entity
WHERE d.mode='FULL' AND r.res_status=1
  AND NOT EXISTS (SELECT 1 FROM $CUR c
                  WHERE c.source_system=f.source_system AND c.source_entity=f.source_entity
                    AND c.business_key=r.res_code);

-- The provider's name for each resource. In this corpus every provider
-- uses the resource's own code, so alias = code.
INSERT INTO res_alias_stg(res_type, res_alias, res_code, srcd_ts)
SELECT res_type, res_code, res_code, srcd_ts FROM res_stg WHERE load_oper='U';

-- Measurements: one narrow numeric row = one METRIC_STG row.
-- These are read from the STAGE, not from source_landing. The landing
-- keeps the newest row per (key, attribute), which is right for a
-- descriptor and wrong for a measurement: two prices at two times are
-- two observations, not an old value and a new one. So the dedup key
-- here includes the time, and only a true duplicate (same key, same
-- attribute, same extract_ts) collapses -- last row in the file wins.
INSERT INTO metric_stg(batch_no, res_type, res_alias, metric_code, provider_name,
                       start_ts, end_ts, sample_tz_code, duration, value,
                       value_max, value_min, value_cnt, summary_level, sequence_no, srcd_ts)
SELECT $bno, f.res_type, c.business_key, m.metric_code, c.source_system,
       datetime(c.extract_ts), NULL, 'UTC', NULL, c.value_num,
       NULL, NULL, NULL, NULL,
       ROW_NUMBER() OVER (ORDER BY f.res_type, c.business_key, m.metric_code, c.extract_ts),
       '$q_bts'
FROM (SELECT *, ROW_NUMBER() OVER (
              PARTITION BY source_system, source_entity, business_key, attribute_name, extract_ts
              ORDER BY rowid DESC) AS rn
      FROM source_landing_stage) c
JOIN meta_feed_map f ON f.source_system=c.source_system AND f.source_entity=c.source_entity
                    AND f.role='RES'
JOIN meta_attribute_map m ON m.source_system=c.source_system
                         AND m.source_entity=c.source_entity
                         AND m.source_attribute=c.attribute_name
                         AND m.target_kind='METRIC'
WHERE c.rn = 1 AND c.op <> 'DELETE' AND c.value_num IS NOT NULL;

-- Memberships: one business key = one (group, member) pair.
INSERT INTO res_resgrp_stg(res_type, res_alias, group_path, srcd_ts)
SELECT f.member_res_type,
       MAX(CASE WHEN c.attribute_name=f.member_attribute THEN c.value_str END),
       f.group_root || '/' || MAX(CASE WHEN c.attribute_name=f.group_attribute THEN c.value_str END),
       datetime(MAX(c.extract_ts))
FROM $CUR c
JOIN meta_feed_map f ON f.source_system=c.source_system AND f.source_entity=c.source_entity
                    AND f.role='MEMBER'
WHERE c.op <> 'DELETE'
GROUP BY f.source_system, f.source_entity, f.member_res_type, f.group_root, c.business_key
HAVING MAX(CASE WHEN c.attribute_name=f.member_attribute THEN c.value_str END) IS NOT NULL
   AND MAX(CASE WHEN c.attribute_name=f.group_attribute  THEN c.value_str END) IS NOT NULL;
-- Calendar events named by the delivery. An attribute that did not
-- arrive keeps the event's current value; a tombstone for an event the
-- mart does not hold has nothing to delete and is dropped.
INSERT INTO calndr_event_stg(batch_no, load_oper, event_code, sequence_no, srcd_ts $EV_COLS)
WITH k AS (
  SELECT c.business_key AS event_code,
         CASE WHEN MAX(CASE WHEN c.op =  'DELETE' THEN c.extract_ts END) IS NOT NULL
               AND (MAX(CASE WHEN c.op <> 'DELETE' THEN c.extract_ts END) IS NULL
                    OR MAX(CASE WHEN c.op =  'DELETE' THEN c.extract_ts END)
                    >= MAX(CASE WHEN c.op <> 'DELETE' THEN c.extract_ts END))
              THEN 'D' ELSE 'U' END AS load_oper,
         datetime(MAX(c.extract_ts)) AS ext_ts
         $EV_PIVOT
  FROM $CUR c
  JOIN meta_feed_map f ON f.source_system=c.source_system AND f.source_entity=c.source_entity
                      AND f.role='EVENT'
  GROUP BY c.business_key)
SELECT $bno, k.load_oper, k.event_code,
       ROW_NUMBER() OVER (ORDER BY k.event_code), k.ext_ts
       $EV_MERGE
FROM k
LEFT JOIN calndr_event e ON e.event_code = k.event_code
LEFT JOIN res_grp g      ON g.res_grp_id = e.res_grp_id
LEFT JOIN cal_evt_grp xg ON xg.event_grp_id = e.event_grp_id
WHERE k.load_oper = 'U' OR e.event_id IS NOT NULL;

-- >> ABSENCE means DELETE only for a FULL delivery. << This assumes one
-- calendar feed: every held event belongs to it.
INSERT INTO calndr_event_stg(batch_no, load_oper, event_code, sequence_no, srcd_ts,
                             group_path, cal_evt_type, inheritance_flag, event_start_tm)
SELECT $bno, 'D', e.event_code,
       (SELECT COALESCE(MAX(sequence_no),0) FROM calndr_event_stg)
         + ROW_NUMBER() OVER (ORDER BY e.event_code),
       datetime(d.ext_ts), g.group_path, e.cal_evt_type, e.inheritance_flag, e.event_start_tm
FROM calndr_event e
JOIN res_grp g ON g.res_grp_id = e.res_grp_id
JOIN (SELECT c.source_system, c.source_entity,
             COALESCE(MAX(c.load_mode),'INCREMENTAL') AS mode, MAX(c.extract_ts) AS ext_ts
      FROM $CUR c JOIN meta_feed_map f ON f.source_system=c.source_system
                                      AND f.source_entity=c.source_entity AND f.role='EVENT'
      GROUP BY c.source_system, c.source_entity) d ON d.mode = 'FULL'
WHERE NOT EXISTS (SELECT 1 FROM $CUR c
                  WHERE c.source_system=d.source_system AND c.source_entity=d.source_entity
                    AND c.business_key=e.event_code);
COMMIT;"

printf "    routed: res_stg=%s (deletes=%s)  metric_stg=%s  res_resgrp_stg=%s  calndr_event_stg=%s\n" \
  "$(sql_scalar "SELECT COUNT(*) FROM res_stg;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM res_stg WHERE load_oper='D';")" \
  "$(sql_scalar "SELECT COUNT(*) FROM metric_stg;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM res_resgrp_stg;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM calndr_event_stg;")"
