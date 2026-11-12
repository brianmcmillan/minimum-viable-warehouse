#!/usr/bin/env bash
# ---------------------------------------------------------------------
# LOAD CALENDAR EVENTS from CALNDR_EVENT_STG. One transaction.
#
# Every event targets a RES_GRP by path, and is stored against its
# res_grp_id. A target must be one of:
#   * a group that already exists (a feed group, or /TYPE/<res_type>);
#   * /RES/<res_type>/<res_code>, a single resource. The group is
#     created the first time an event targets it, with the resource as
#     its one member. Membership is by res_id, so the event stays with
#     the resource if its code ever changes.
# Anything else fails the load, as does an unknown cal_evt_type (FK).
#
# An event may also belong to an event group (CAL_EVT_GRP), named in the
# feed by event_grp. A new name creates the group; ids continue from the
# maximum in code order. The staging rows get their event_grp_id here.
#
# CALNDR_EVENT has no status column, so a deleted event is a physical
# DELETE. Changed events update in place; unchanged ones write nothing.
# New event_ids continue from the maximum in event_code order.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
q_bts="$(sql_quote "$BATCH_TS")"

# '/RES/CUSTOMER/C001' -> res_type 'CUSTOMER', code 'C001'
SINGLETONS="SELECT group_path AS gp,
                   substr(group_path, 6, instr(substr(group_path, 6), '/') - 1) AS t,
                   substr(group_path, 6 + instr(substr(group_path, 6), '/')) AS c
            FROM calndr_event_stg
            WHERE load_oper = 'U' AND group_path LIKE '/RES/%/%'"

sql_tx "
BEGIN;
DELETE FROM load_guard;

INSERT INTO load_guard(rule, violations)
SELECT 'calendar event targets a group that does not exist', COUNT(*)
FROM calndr_event_stg s
WHERE s.load_oper = 'U' AND s.group_path NOT LIKE '/RES/%/%'
  AND NOT EXISTS (SELECT 1 FROM res_grp g WHERE g.group_path = s.group_path);

INSERT INTO load_guard(rule, violations)
SELECT 'calendar event targets /RES/<type>/<code> for an unknown resource', COUNT(*)
FROM ($SINGLETONS) s
WHERE NOT EXISTS (SELECT 1 FROM res_alias a WHERE a.res_type = s.t AND a.res_alias = s.c);

$(ensure_groups_sql "SELECT gp FROM ($SINGLETONS)")

INSERT INTO res_resgrp(res_grp_id, res_id, srcd_ts)
SELECT DISTINCT g.res_grp_id, a.res_id, '$q_bts'
FROM ($SINGLETONS) s
JOIN res_grp g   ON g.group_path = s.gp
JOIN res_alias a ON a.res_type = s.t AND a.res_alias = s.c
WHERE NOT EXISTS (SELECT 1 FROM res_resgrp x WHERE x.res_grp_id = g.res_grp_id);

-- Event groups: an open domain.
INSERT INTO cal_evt_grp(event_grp_id, event_grp_code, event_grp_name, srcd_ts)
SELECT (SELECT COALESCE(MAX(event_grp_id), 0) FROM cal_evt_grp)
         + ROW_NUMBER() OVER (ORDER BY c), c, c, '$q_bts'
FROM (SELECT DISTINCT event_grp_code AS c FROM calndr_event_stg
      WHERE load_oper = 'U' AND event_grp_code IS NOT NULL
        AND event_grp_code NOT IN (SELECT event_grp_code FROM cal_evt_grp));

UPDATE calndr_event_stg
SET event_grp_id = (SELECT event_grp_id FROM cal_evt_grp WHERE event_grp_code = calndr_event_stg.event_grp_code);

-- New events.
INSERT INTO calndr_event(event_id, event_code, res_grp_id, event_grp_id, cal_evt_type,
       inheritance_flag, event_start_dt, event_start_tm, duration, active_start_dt,
       active_end_dt, days_of_week, occurs_of_month, days_of_month, month_end_flag,
       months, year, entered_by, srcd_ts, event_desc)
SELECT (SELECT COALESCE(MAX(event_id), 0) FROM calndr_event)
         + ROW_NUMBER() OVER (ORDER BY s.event_code),
       s.event_code, g.res_grp_id, s.event_grp_id, s.cal_evt_type,
       s.inheritance_flag, s.event_start_dt, s.event_start_tm, s.duration, s.active_start_dt,
       s.active_end_dt, s.days_of_week, s.occurs_of_month, s.days_of_month, s.month_end_flag,
       s.months, s.year, s.entered_by, '$q_bts', s.event_desc
FROM calndr_event_stg s JOIN res_grp g ON g.group_path = s.group_path
WHERE s.load_oper = 'U'
  AND NOT EXISTS (SELECT 1 FROM calndr_event e WHERE e.event_code = s.event_code);

-- Changed events: in place, changed rows only.
UPDATE calndr_event SET
       res_grp_id = g.res_grp_id, event_grp_id = s.event_grp_id, cal_evt_type = s.cal_evt_type,
       inheritance_flag = s.inheritance_flag, event_start_dt = s.event_start_dt,
       event_start_tm = s.event_start_tm, duration = s.duration,
       active_start_dt = s.active_start_dt, active_end_dt = s.active_end_dt,
       days_of_week = s.days_of_week, occurs_of_month = s.occurs_of_month,
       days_of_month = s.days_of_month, month_end_flag = s.month_end_flag,
       months = s.months, year = s.year, entered_by = s.entered_by,
       event_desc = s.event_desc, srcd_ts = '$q_bts'
FROM calndr_event_stg s JOIN res_grp g ON g.group_path = s.group_path
WHERE calndr_event.event_code = s.event_code AND s.load_oper = 'U'
  AND (calndr_event.res_grp_id       IS NOT g.res_grp_id
    OR calndr_event.event_grp_id     IS NOT s.event_grp_id
    OR calndr_event.cal_evt_type     IS NOT s.cal_evt_type
    OR calndr_event.inheritance_flag IS NOT s.inheritance_flag
    OR calndr_event.event_start_dt   IS NOT s.event_start_dt
    OR calndr_event.event_start_tm   IS NOT s.event_start_tm
    OR calndr_event.duration         IS NOT s.duration
    OR calndr_event.active_start_dt  IS NOT s.active_start_dt
    OR calndr_event.active_end_dt    IS NOT s.active_end_dt
    OR calndr_event.days_of_week     IS NOT s.days_of_week
    OR calndr_event.occurs_of_month  IS NOT s.occurs_of_month
    OR calndr_event.days_of_month    IS NOT s.days_of_month
    OR calndr_event.month_end_flag   IS NOT s.month_end_flag
    OR calndr_event.months           IS NOT s.months
    OR calndr_event.year             IS NOT s.year
    OR calndr_event.entered_by       IS NOT s.entered_by
    OR calndr_event.event_desc       IS NOT s.event_desc);

-- Deleted events: tombstone, or absence from a FULL delivery.
DELETE FROM calndr_event
WHERE event_code IN (SELECT event_code FROM calndr_event_stg WHERE load_oper = 'D');

INSERT INTO load_guard(rule, violations)
SELECT 'RES_GRP parent, level and path disagree', COUNT(*) FROM v_res_grp_path_violation;
DELETE FROM load_guard;
COMMIT;"

printf "    calendar: %s event(s) in %s event group(s), %s resource group(s)\n" \
  "$(sql_scalar "SELECT COUNT(*) FROM calndr_event;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM cal_evt_grp;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM res_grp;")"
