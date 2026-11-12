#!/usr/bin/env bash
# ---------------------------------------------------------------------
# LOAD RESOURCES from RES_STG / RES_ALIAS_STG, then the subtype columns
# straight from the narrow landing. One transaction.
#
# RES is current state, so this loader UPDATEs in place -- but only a
# row whose value really changed. An unchanged re-delivery writes
# nothing and leaves srcd_ts alone.
#
# Surrogates (provider_id, res_id) continue from the table maximum in
# business-key order, so an ordered replay reproduces them.
#
# The subtype pass is the Anchor-style part: one generated statement per
# meta_attribute_map row, each touching one column of one table. A new
# descriptive attribute still needs DDL first (this is 3NF); only the
# routing is metadata.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
q_bts="$(sql_quote "$BATCH_TS")"

SQL="
BEGIN;
DELETE FROM load_guard;

-- A parent that can't be found, of a type that may not be auto-created.
INSERT INTO load_guard(rule, violations)
SELECT 'parent alias unknown and its res_type does not auto-create', COUNT(*)
FROM res_stg s
WHERE s.load_oper='U' AND s.parent_res_alias IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM res_alias a WHERE a.res_type=s.parent_res_type AND a.res_alias=s.parent_res_alias)
  AND NOT EXISTS (SELECT 1 FROM res_alias_stg a WHERE a.res_type=s.parent_res_type AND a.res_alias=s.parent_res_alias)
  AND NOT EXISTS (SELECT 1 FROM res_type t WHERE t.res_type=s.parent_res_type AND t.autocrt_res_flag=1);

INSERT INTO provider(provider_id, provider_name, srcd_ts, migration_src_fg)
SELECT (SELECT COALESCE(MAX(provider_id),0) FROM provider) + ROW_NUMBER() OVER (ORDER BY ss),
       ss, '$q_bts', 'N'
FROM (SELECT DISTINCT source_system AS ss FROM source_landing_stage)
WHERE ss NOT IN (SELECT provider_name FROM provider);

-- New resources.
INSERT INTO res(res_id, res_type, res_code, res_name, res_short_name, res_tz_code,
                res_status, srcd_ts, res_desc)
SELECT (SELECT COALESCE(MAX(res_id),0) FROM res)
         + ROW_NUMBER() OVER (ORDER BY s.res_type, s.res_code),
       s.res_type, s.res_code, s.res_name, s.res_short_name, s.res_tz_code,
       1, '$q_bts', s.res_desc
FROM res_stg s
WHERE s.load_oper='U'
  AND NOT EXISTS (SELECT 1 FROM res r WHERE r.res_type=s.res_type AND r.res_code=s.res_code);

INSERT INTO res_alias(res_type, res_alias, res_id, srcd_ts)
SELECT a.res_type, a.res_alias, r.res_id, '$q_bts'
FROM res_alias_stg a JOIN res r ON r.res_type=a.res_type AND r.res_code=a.res_code
WHERE NOT EXISTS (SELECT 1 FROM res_alias x WHERE x.res_type=a.res_type AND x.res_alias=a.res_alias);

-- Auto-create: a parent referenced before its own feed has delivered it
-- becomes a stub resource (name = code) when its type allows that.
INSERT INTO res(res_id, res_type, res_code, res_name, res_tz_code, res_status, srcd_ts)
SELECT (SELECT COALESCE(MAX(res_id),0) FROM res) + ROW_NUMBER() OVER (ORDER BY p.t, p.a),
       p.t, p.a, p.a, 'UTC', 1, '$q_bts'
FROM (SELECT DISTINCT parent_res_type AS t, parent_res_alias AS a FROM res_stg
      WHERE load_oper='U' AND parent_res_alias IS NOT NULL) p
WHERE NOT EXISTS (SELECT 1 FROM res_alias x WHERE x.res_type=p.t AND x.res_alias=p.a);

INSERT INTO res_alias(res_type, res_alias, res_id, srcd_ts)
SELECT r.res_type, r.res_code, r.res_id, '$q_bts'
FROM res r
WHERE NOT EXISTS (SELECT 1 FROM res_alias x WHERE x.res_type=r.res_type AND x.res_alias=r.res_code);

-- Changed descriptors: UPDATE in place, changed rows only.
UPDATE res SET res_name=s.res_name, res_short_name=s.res_short_name,
               res_desc=s.res_desc, srcd_ts='$q_bts'
FROM res_stg s
WHERE res.res_type=s.res_type AND res.res_code=s.res_code AND s.load_oper='U'
  AND (res.res_name IS NOT s.res_name OR res.res_short_name IS NOT s.res_short_name
       OR res.res_desc IS NOT s.res_desc);

-- Parent (re-)pointing. The old parent is overwritten, not versioned.
UPDATE res SET parent_res=p.res_id, srcd_ts='$q_bts'
FROM res_stg s JOIN res_alias p ON p.res_type=s.parent_res_type AND p.res_alias=s.parent_res_alias
WHERE res.res_type=s.res_type AND res.res_code=s.res_code AND s.load_oper='U'
  AND res.parent_res IS NOT p.res_id;

-- Restore: a deleted resource delivered again is live again.
UPDATE res SET res_status=1, srcd_ts='$q_bts'
FROM res_stg s
WHERE res.res_type=s.res_type AND res.res_code=s.res_code AND s.load_oper='U'
  AND res.res_status=0;

-- Delete: tombstone, or absence from a FULL delivery (decided by the router).
UPDATE res SET res_status=0, srcd_ts='$q_bts'
FROM res_stg s
WHERE res.res_type=s.res_type AND res.res_code=s.res_code AND s.load_oper='D'
  AND res.res_status=1;
"

# ---- subtype tables: one row per resource of the type, then one
# ---- generated UPDATE per mapped attribute.
while IFS='|' read -r tbl rtype; do
  [ -n "$tbl" ] || continue
  tbl="$(sql_ident "$tbl")"
  SQL+="
INSERT INTO $tbl(res_id, srcd_ts)
SELECT r.res_id, '$q_bts' FROM res r
WHERE r.res_type='$(sql_quote "$rtype")' AND r.res_id NOT IN (SELECT res_id FROM $tbl);
"
done < <(sql_run "SELECT DISTINCT m.target_table||'|'||f.res_type
                  FROM meta_attribute_map m
                  JOIN meta_feed_map f ON f.source_system=m.source_system
                                      AND f.source_entity=m.source_entity
                  WHERE m.target_kind='SUBTYPE' ORDER BY 1;")

while IFS='|' read -r ss se attr tbl col slot rtype reft refc refo; do
  [ -n "$ss" ] || continue
  tbl="$(sql_ident "$tbl")"; col="$(sql_ident "$col")"; slot="$(sql_ident "$slot")"
  src="SELECT r.res_id, l.$slot AS v
       FROM $CUR l JOIN res r ON r.res_type='$(sql_quote "$rtype")' AND r.res_code=l.business_key
       WHERE l.source_system='$(sql_quote "$ss")' AND l.source_entity='$(sql_quote "$se")'
         AND l.attribute_name='$(sql_quote "$attr")' AND l.op <> 'DELETE'"
  if [ -n "$reft" ] && [ "$refo" = "1" ]; then      # open code table: learn new codes
    reft="$(sql_ident "$reft")"; refc="$(sql_ident "$refc")"
    SQL+="
INSERT INTO $reft($refc, srcd_ts)
SELECT DISTINCT c.v, '$q_bts' FROM ($src) c
WHERE c.v IS NOT NULL AND c.v NOT IN (SELECT $refc FROM $reft) ORDER BY c.v;
"
  fi
  SQL+="
UPDATE $tbl SET $col=c.v, srcd_ts='$q_bts'
FROM ($src) c
WHERE $tbl.res_id=c.res_id AND $tbl.$col IS NOT c.v;
"
done < <(sql_run "SELECT m.source_system||'|'||m.source_entity||'|'||m.source_attribute||'|'||
                         m.target_table||'|'||m.target_col||'|'||m.slot||'|'||f.res_type||'|'||
                         COALESCE(m.ref_table,'')||'|'||COALESCE(m.ref_col,'')||'|'||COALESCE(m.ref_open,'')
                  FROM meta_attribute_map m
                  JOIN meta_feed_map f ON f.source_system=m.source_system
                                      AND f.source_entity=m.source_entity
                  WHERE m.target_kind='SUBTYPE'
                  ORDER BY m.source_system, m.source_entity, m.source_attribute;")

SQL+="
-- RES_TYPE_REL is not enforced by any key in the diagram; enforce it here.
INSERT INTO load_guard(rule, violations)
SELECT 'parent/child resource types not allowed by RES_TYPE_REL', COUNT(*)
FROM v_res_type_rel_violation;
DELETE FROM load_guard;
COMMIT;"

sql_tx "$SQL"
printf "    resources: %s live, %s deleted, %s alias(es)\n" \
  "$(sql_scalar "SELECT COUNT(*) FROM res WHERE res_status=1;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM res WHERE res_status=0;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM res_alias;")"
