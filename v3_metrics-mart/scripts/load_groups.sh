#!/usr/bin/env bash
# ---------------------------------------------------------------------
# LOAD GROUPS and memberships. One transaction.
#
# A group is identified by its path. ensure_groups_sql (lib.sh) creates
# a group and every ancestor it needs, deriving parent and level from
# the path; v_res_grp_path_violation is checked before commit.
#
# Two kinds of group are maintained here:
#   * feed groups, from RES_RESGRP_STG (an order's products are the
#     members of /ORDER/<order_ref>);
#   * type groups, /TYPE/<res_type>, one per resource type, holding
#     every resource of that type. They exist so a calendar event can
#     target a whole type through RES_GRP like any other group.
#
# RES_RESGRP has no status column, so a feed membership that ends is a
# physical DELETE, under the same rule as everything else: a tombstone
# always, absence only when the member feed's delivery is FULL. Type
# groups never lose members: a resource's type does not change, and a
# deleted resource keeps its row in RES.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
q_bts="$(sql_quote "$BATCH_TS")"

# The feeds of role MEMBER carried by this delivery, with their mode.
MEMBER_FEEDS="(SELECT f.source_system, f.source_entity, f.group_root, f.member_res_type,
                      COALESCE(MAX(s.load_mode),'INCREMENTAL') AS mode
               FROM meta_feed_map f
               JOIN source_landing_stage s ON s.source_system=f.source_system
                                          AND s.source_entity=f.source_entity
               WHERE f.role='MEMBER'
               GROUP BY f.source_system, f.source_entity, f.group_root, f.member_res_type)"

sql_tx "
BEGIN;
DELETE FROM load_guard;

INSERT INTO load_guard(rule, violations)
SELECT 'group member alias does not resolve to a resource', COUNT(*)
FROM res_resgrp_stg s
WHERE NOT EXISTS (SELECT 1 FROM res_alias a WHERE a.res_type=s.res_type AND a.res_alias=s.res_alias);

$(ensure_groups_sql "SELECT group_path FROM res_resgrp_stg
                     UNION SELECT '/TYPE/' || res_type FROM res_type")

-- Type groups: every resource of the type is a member.
INSERT INTO res_resgrp(res_grp_id, res_id, srcd_ts)
SELECT g.res_grp_id, r.res_id, '$q_bts'
FROM res r JOIN res_grp g ON g.group_path = '/TYPE/' || r.res_type
WHERE NOT EXISTS (SELECT 1 FROM res_resgrp x
                  WHERE x.res_grp_id=g.res_grp_id AND x.res_id=r.res_id)
ORDER BY g.res_grp_id, r.res_id;

INSERT INTO res_resgrp(res_grp_id, res_id, srcd_ts)
SELECT g.res_grp_id, a.res_id, '$q_bts'
FROM res_resgrp_stg s
JOIN res_grp g   ON g.group_path=s.group_path
JOIN res_alias a ON a.res_type=s.res_type AND a.res_alias=s.res_alias
WHERE NOT EXISTS (SELECT 1 FROM res_resgrp x
                  WHERE x.res_grp_id=g.res_grp_id AND x.res_id=a.res_id);

-- >> ABSENCE means DELETE only for a FULL delivery. <<
DELETE FROM res_resgrp
WHERE EXISTS (SELECT 1 FROM $MEMBER_FEEDS mf JOIN res_grp g
                ON substr(g.group_path, 1, length(mf.group_root) + 1) = mf.group_root || '/'
              WHERE mf.mode='FULL' AND g.res_grp_id=res_resgrp.res_grp_id)
  AND NOT EXISTS (SELECT 1 FROM res_resgrp_stg s
                  JOIN res_grp g   ON g.group_path=s.group_path
                  JOIN res_alias a ON a.res_type=s.res_type AND a.res_alias=s.res_alias
                  WHERE g.res_grp_id=res_resgrp.res_grp_id AND a.res_id=res_resgrp.res_id);

-- Tombstones. A membership key is '<group value>~<member alias>'.
DELETE FROM res_resgrp
WHERE EXISTS (SELECT 1
              FROM $CUR c
              JOIN meta_feed_map f ON f.source_system=c.source_system
                                  AND f.source_entity=c.source_entity AND f.role='MEMBER'
              JOIN res_grp g   ON g.group_path = f.group_root || '/' ||
                                  substr(c.business_key, 1, instr(c.business_key,'~') - 1)
              JOIN res_alias a ON a.res_type = f.member_res_type
                              AND a.res_alias = substr(c.business_key, instr(c.business_key,'~') + 1)
              WHERE c.op='DELETE'
                AND g.res_grp_id=res_resgrp.res_grp_id AND a.res_id=res_resgrp.res_id);

INSERT INTO load_guard(rule, violations)
SELECT 'RES_GRP parent, level and path disagree', COUNT(*) FROM v_res_grp_path_violation;
DELETE FROM load_guard;
COMMIT;"

printf "    groups: %s group(s), %s membership(s)\n" \
  "$(sql_scalar "SELECT COUNT(*) FROM res_grp;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM res_resgrp;")"
