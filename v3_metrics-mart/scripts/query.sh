#!/usr/bin/env bash
# Pretty-print the mart. The first block mirrors the sibling demos'
# query.sh so outputs compare directly.
source "$(dirname "$0")/lib.sh"
show() { echo; echo "### $1"; shift; sql_table "$1"; }

echo "======================================================================"
echo "  BUSINESS PERSPECTIVES  (current state; price and amount are samples)"
echo "======================================================================"
show "Customers" "SELECT * FROM v_customer ORDER BY customer_ref;"
show "Products"  "SELECT * FROM v_product  ORDER BY sku;"
show "Orders"    "SELECT * FROM v_order    ORDER BY order_ref;"

echo; echo "======================================================================"
echo "  RESOURCES: one table, every type, deletes as res_status"
echo "======================================================================"
show "RES" "SELECT res_id, res_type, res_code, res_name, status, parent FROM v_res ORDER BY res_id;"

echo; echo "======================================================================"
echo "  METRICS: a metric is a row; a sample is an observation"
echo "======================================================================"
show "METRIC" "SELECT metric_id, metric_code, value_type, unit_of_measure FROM metric ORDER BY metric_id;"
show "METRIC_SAMPLE (history lives here, including deleted resources)" \
  "SELECT * FROM v_metric_sample ORDER BY res_type, res_code, metric_code, sample_utc_ts;"

echo; echo "======================================================================"
echo "  AGGREGATIONS: derived after every delivery"
echo "======================================================================"
show "METRIC_WEEKLY" \
  "SELECT * FROM v_metric_weekly ORDER BY res_type, res_code, metric_code, week_start;"
show "Group weeks: each order's basket at list price" \
  "SELECT group_path, week_start, members, round(value_sum, 2) AS basket_at_list_price
   FROM v_group_weekly WHERE metric_code='price' AND group_path LIKE '/ORDER/%'
   ORDER BY group_path, week_start;"

echo; echo "======================================================================"
echo "  CALENDAR: every event targets a RES_GRP"
echo "======================================================================"
show "CALNDR_EVENT" "SELECT event_code, event_grp_code AS event_grp, cal_evt_type, target,
                             inheritance_flag AS inherit, event_desc
                      FROM v_calndr_event ORDER BY event_code;"
show "Occurrences per event and the resources each one reaches" \
  "SELECT o.event_code, COUNT(DISTINCT o.occur_dt) AS dates,
          MIN(o.occur_dt) AS first_dt, MAX(o.occur_dt) AS last_dt,
          (SELECT group_concat(res_code, ',') FROM (SELECT DISTINCT res_code FROM v_res_calendar r
            WHERE r.event_code = o.event_code AND r.res_status = 'LIVE' ORDER BY res_code)) AS live_resources
   FROM v_calndr_occurrence o GROUP BY o.event_code ORDER BY o.event_code;"

echo; echo "======================================================================"
echo "  CONTEXT FOR A DECISION LAYER: samples taken while an event was in effect"
echo "======================================================================"
show "Metric samples with the calendar events active that day" \
  "SELECT res_code, metric_code, date(sample_utc_ts) AS sample_dt, value,
          event_code, event_grp_code AS event_grp, cal_evt_type
   FROM v_metric_sample_event ORDER BY res_code, sample_utc_ts, event_code;"
