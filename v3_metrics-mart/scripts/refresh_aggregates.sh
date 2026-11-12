#!/usr/bin/env bash
# ---------------------------------------------------------------------
# REFRESH the derived tables. One transaction.
#
#   METRIC_SAMPLE  -> METRIC_SUMMARY ('D': one UTC day per resource,
#                                     metric and provider)
#   METRIC_SUMMARY -> METRIC_WEEKLY  (weeks start on Monday)
#   METRIC_WEEKLY x RES_RESGRP -> GRP_METRIC_WEEKLY
#
# Each table is recomputed in full and then reconciled: a row that no
# longer belongs is deleted, a row whose numbers changed is updated, an
# unchanged row is not touched. So srcd_ts still means "last changed",
# and a delivery with no new samples writes nothing here.
#
# Group weeks use the group's CURRENT members for every week, because
# RES_RESGRP keeps no membership history.
# ---------------------------------------------------------------------
source "$(dirname "$0")/lib.sh"
q_bts="$(sql_quote "$BATCH_TS")"

sql_tx "
BEGIN;

CREATE TEMP TABLE t_sum AS
SELECT res_id, metric_id, 'D' AS summary_level,
       date(sample_utc_ts) || ' 00:00:00' AS start_utc_ts, provider_id,
       MAX(res_tz_code) AS res_tz_code,
       AVG(value) AS value, MAX(value) AS value_max, MIN(value) AS value_min,
       COUNT(*) AS value_cnt
FROM metric_sample
GROUP BY res_id, metric_id, date(sample_utc_ts), provider_id;

DELETE FROM metric_summary
WHERE summary_level='D'
  AND NOT EXISTS (SELECT 1 FROM t_sum t
                  WHERE t.res_id=metric_summary.res_id AND t.metric_id=metric_summary.metric_id
                    AND t.start_utc_ts=metric_summary.start_utc_ts
                    AND t.provider_id=metric_summary.provider_id);
INSERT INTO metric_summary(res_id, metric_id, summary_level, start_utc_ts, provider_id,
                           res_tz_code, start_lcl_ts, duration, value, value_max, value_min,
                           value_cnt, srcd_ts)
SELECT res_id, metric_id, summary_level, start_utc_ts, provider_id, res_tz_code,
       start_utc_ts, 86400, value, value_max, value_min, value_cnt, '$q_bts'
FROM t_sum WHERE true
ON CONFLICT(res_id, metric_id, summary_level, start_utc_ts, provider_id)
DO UPDATE SET value=excluded.value, value_max=excluded.value_max,
              value_min=excluded.value_min, value_cnt=excluded.value_cnt,
              srcd_ts=excluded.srcd_ts
WHERE metric_summary.value IS NOT excluded.value
   OR metric_summary.value_max IS NOT excluded.value_max
   OR metric_summary.value_min IS NOT excluded.value_min
   OR metric_summary.value_cnt IS NOT excluded.value_cnt;

-- date(d,'weekday 0','-6 days') is the Monday on or before d.
CREATE TEMP TABLE t_wk AS
SELECT res_id, metric_id,
       date(start_utc_ts, 'weekday 0', '-6 days') AS start_lcl_dt, provider_id,
       MAX(res_tz_code) AS lcl_tz_code,
       SUM(value * value_cnt) / SUM(value_cnt) AS value,
       MAX(value_max) AS value_max, MIN(value_min) AS value_min,
       SUM(value_cnt) AS value_cnt
FROM metric_summary WHERE summary_level='D'
GROUP BY res_id, metric_id, date(start_utc_ts, 'weekday 0', '-6 days'), provider_id;

DELETE FROM metric_weekly
WHERE NOT EXISTS (SELECT 1 FROM t_wk t
                  WHERE t.res_id=metric_weekly.res_id AND t.metric_id=metric_weekly.metric_id
                    AND t.start_lcl_dt=metric_weekly.start_lcl_dt
                    AND t.provider_id=metric_weekly.provider_id);
INSERT INTO metric_weekly(res_id, metric_id, start_lcl_dt, provider_id, lcl_tz_code,
                          value, value_max, value_min, value_cnt, srcd_ts)
SELECT res_id, metric_id, start_lcl_dt, provider_id, lcl_tz_code,
       value, value_max, value_min, value_cnt, '$q_bts'
FROM t_wk WHERE true
ON CONFLICT(res_id, metric_id, start_lcl_dt, provider_id)
DO UPDATE SET value=excluded.value, value_max=excluded.value_max,
              value_min=excluded.value_min, value_cnt=excluded.value_cnt,
              srcd_ts=excluded.srcd_ts
WHERE metric_weekly.value IS NOT excluded.value
   OR metric_weekly.value_max IS NOT excluded.value_max
   OR metric_weekly.value_min IS NOT excluded.value_min
   OR metric_weekly.value_cnt IS NOT excluded.value_cnt;

CREATE TEMP TABLE t_gwk AS
SELECT w.res_id, x.res_grp_id, w.metric_id, w.start_lcl_dt, w.provider_id,
       w.lcl_tz_code, w.value, w.value_max, w.value_min, w.value_cnt
FROM metric_weekly w JOIN res_resgrp x ON x.res_id=w.res_id;

DELETE FROM grp_metric_weekly
WHERE NOT EXISTS (SELECT 1 FROM t_gwk t
                  WHERE t.res_id=grp_metric_weekly.res_id
                    AND t.res_grp_id=grp_metric_weekly.res_grp_id
                    AND t.metric_id=grp_metric_weekly.metric_id
                    AND t.start_lcl_dt=grp_metric_weekly.start_lcl_dt
                    AND t.provider_id=grp_metric_weekly.provider_id);
INSERT INTO grp_metric_weekly(res_id, res_grp_id, metric_id, start_lcl_dt, provider_id,
                              lcl_tz_code, value, value_max, value_min, value_cnt, srcd_ts)
SELECT res_id, res_grp_id, metric_id, start_lcl_dt, provider_id, lcl_tz_code,
       value, value_max, value_min, value_cnt, '$q_bts'
FROM t_gwk WHERE true
ON CONFLICT(res_id, res_grp_id, metric_id, start_lcl_dt, provider_id)
DO UPDATE SET value=excluded.value, value_max=excluded.value_max,
              value_min=excluded.value_min, value_cnt=excluded.value_cnt,
              srcd_ts=excluded.srcd_ts
WHERE grp_metric_weekly.value IS NOT excluded.value
   OR grp_metric_weekly.value_max IS NOT excluded.value_max
   OR grp_metric_weekly.value_min IS NOT excluded.value_min
   OR grp_metric_weekly.value_cnt IS NOT excluded.value_cnt;
COMMIT;"

printf "    aggregates: summary=%s weekly=%s group-weekly=%s\n" \
  "$(sql_scalar "SELECT COUNT(*) FROM metric_summary;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM metric_weekly;")" \
  "$(sql_scalar "SELECT COUNT(*) FROM grp_metric_weekly;")"
