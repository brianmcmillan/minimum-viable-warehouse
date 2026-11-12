-- =====================================================================
-- METRICS MART :: READ MODEL
-- ---------------------------------------------------------------------
-- v_customer / v_product / v_order / v_order_line are column-for-column
-- with the Anchor demo's perspectives, so outputs compare directly.
-- =====================================================================

-- The newest sample per resource, metric and provider.
CREATE VIEW v_metric_latest AS
SELECT res_id, metric_id, provider_id, sample_utc_ts, value FROM (
  SELECT s.*, ROW_NUMBER() OVER (PARTITION BY res_id, metric_id, provider_id
                                 ORDER BY sample_utc_ts DESC) AS rn
  FROM metric_sample s) WHERE rn = 1;

-------------------------- business perspectives -------------------------

CREATE VIEW v_customer AS
SELECT r.res_code    AS customer_ref,
       r.res_name    AS customer_name,
       c.email_addr  AS email,
       c.signup_date AS signup_date
FROM res r LEFT JOIN res_customer c ON c.res_id = r.res_id
WHERE r.res_type = 'CUSTOMER' AND r.res_status = 1;

-- price is not a column: it is the newest 'price' sample.
CREATE VIEW v_product AS
SELECT r.res_code      AS sku,
       r.res_name      AS product_name,
       (SELECT l.value FROM v_metric_latest l JOIN metric m ON m.metric_id = l.metric_id
         WHERE l.res_id = r.res_id AND m.metric_code = 'price') AS price,
       p.currency_code AS currency
FROM res r LEFT JOIN res_product p ON p.res_id = r.res_id
WHERE r.res_type = 'PRODUCT' AND r.res_status = 1;

-- status is decoded on read by joining the code table; placed_by is the
-- parent resource, if it is still live.
CREATE VIEW v_order AS
SELECT r.res_code      AS order_ref,
       s.status_name   AS status,
       (SELECT l.value FROM v_metric_latest l JOIN metric m ON m.metric_id = l.metric_id
         WHERE l.res_id = r.res_id AND m.metric_code = 'amount') AS amount,
       o.currency_code AS currency,
       o.placed_at     AS placed_at,
       (SELECT p.res_name FROM res p
         WHERE p.res_id = r.parent_res AND p.res_status = 1)    AS placed_by
FROM res r
LEFT JOIN res_order o    ON o.res_id = r.res_id
LEFT JOIN order_status s ON s.status_code = o.status_code
WHERE r.res_type = 'ORDER' AND r.res_status = 1;

CREATE VIEW v_order_line AS
SELECT g.res_grp_name AS order_ref, r.res_code AS sku
FROM res_resgrp x
JOIN res_grp g ON g.res_grp_id = x.res_grp_id
JOIN res r     ON r.res_id = x.res_id
WHERE g.group_path LIKE '/ORDER/%';

------------------------------ the mart itself ---------------------------

-- Every resource, live or deleted, with its parent.
CREATE VIEW v_res AS
SELECT r.res_id, r.res_type, r.res_code, r.res_name,
       CASE r.res_status WHEN 1 THEN 'LIVE' ELSE 'DELETED' END AS status,
       p.res_type || ':' || p.res_code AS parent, r.srcd_ts
FROM res r LEFT JOIN res p ON p.res_id = r.parent_res;

CREATE VIEW v_metric_sample AS
SELECT r.res_type, r.res_code, m.metric_code, p.provider_name,
       s.sample_utc_ts, s.value
FROM metric_sample s
JOIN res r      ON r.res_id = s.res_id
JOIN metric m   ON m.metric_id = s.metric_id
JOIN provider p ON p.provider_id = s.provider_id;

CREATE VIEW v_metric_weekly AS
SELECT r.res_type, r.res_code, m.metric_code, w.start_lcl_dt AS week_start,
       w.value, w.value_min, w.value_max, w.value_cnt
FROM metric_weekly w
JOIN res r    ON r.res_id = w.res_id
JOIN metric m ON m.metric_id = w.metric_id;

-- Group roll-up: the members' weekly values summed per group. For an
-- order group and the 'price' metric this is the basket at list price.
CREATE VIEW v_group_weekly AS
SELECT g.group_path, m.metric_code, w.start_lcl_dt AS week_start,
       COUNT(*) AS members, SUM(w.value) AS value_sum
FROM grp_metric_weekly w
JOIN res_grp g ON g.res_grp_id = w.res_grp_id
JOIN metric m  ON m.metric_id = w.metric_id
GROUP BY g.group_path, m.metric_code, w.start_lcl_dt;

----------------------------- integrity views ----------------------------
-- Both must be empty. The loaders check them through load_guard.

-- A resource whose parent is of a type RES_TYPE_REL does not allow.
CREATE VIEW v_res_type_rel_violation AS
SELECT c.res_type AS child_res_type, c.res_code AS child_res_code,
       p.res_type AS parent_res_type, p.res_code AS parent_res_code
FROM res c JOIN res p ON p.res_id = c.parent_res
WHERE NOT EXISTS (SELECT 1 FROM res_type_rel t
                  WHERE t.parent_res_type = p.res_type
                    AND t.child_res_type  = c.res_type);

-- RES_GRP stores one hierarchy three ways (parent, level, path). This
-- lists any group where the three disagree.
CREATE VIEW v_res_grp_path_violation AS
SELECT g.res_grp_id, g.group_path, g.group_level, g.parent_res_grp
FROM res_grp g LEFT JOIN res_grp p ON p.res_grp_id = g.parent_res_grp
WHERE g.group_level IS NOT (length(g.group_path) - length(replace(g.group_path,'/','')))
   OR (g.parent_res_grp IS NULL     AND g.group_level <> 1)
   OR (g.parent_res_grp IS NOT NULL AND g.group_path <> p.group_path || '/' || g.res_grp_name);

-------------------------------- calendar --------------------------------

-- Every date each event falls on, inside the CALNDR range.
CREATE VIEW v_calndr_occurrence AS
SELECT e.event_id, e.event_code, e.event_grp_id, e.res_grp_id, e.cal_evt_type, e.inheritance_flag,
       c.calndr_date AS occur_dt, e.event_start_tm AS start_tm, e.duration
FROM calndr_event e
JOIN calndr c ON
  CASE WHEN e.days_of_week IS NULL AND e.occurs_of_month IS NULL AND e.days_of_month IS NULL
            AND COALESCE(e.month_end_flag,0) = 0 AND e.months IS NULL
       THEN c.calndr_date = e.event_start_dt                          -- one-off
       ELSE c.calndr_date >= COALESCE(e.active_start_dt, e.event_start_dt, '0000-01-01')
        AND c.calndr_date >= COALESCE(e.event_start_dt, '0000-01-01')
        AND c.calndr_date <= COALESCE(e.active_end_dt, '9999-12-31')
        AND (e.days_of_week    IS NULL OR substr(e.days_of_week,    c.day_of_week,    1) = 'Y')
        AND (e.occurs_of_month IS NULL OR substr(e.occurs_of_month, c.occur_of_month, 1) = 'Y')
        AND (e.days_of_month   IS NULL OR substr(e.days_of_month,   c.day_of_month,   1) = 'Y')
        AND (COALESCE(e.month_end_flag,0) = 0 OR c.month_end_flag = 1)
        AND (e.months          IS NULL OR substr(e.months,          c.month,          1) = 'Y')
  END
 AND (e.year IS NULL OR c.year = e.year);

-- Which resources each occurrence reaches. A resource is reached when it
-- is a member of the event's group or, with inheritance_flag = 1, of any
-- group below it. The prefix test includes the trailing '/', so /ORDER
-- reaches /ORDER/O-100 but not /ORDERS.
CREATE VIEW v_res_calendar AS
SELECT DISTINCT r.res_id, r.res_type, r.res_code,
       CASE r.res_status WHEN 1 THEN 'LIVE' ELSE 'DELETED' END AS res_status,
       o.event_code, xg.event_grp_code, o.cal_evt_type, eg.group_path AS event_group,
       o.occur_dt, o.start_tm, o.duration
FROM v_calndr_occurrence o
JOIN res_grp eg ON eg.res_grp_id = o.res_grp_id
LEFT JOIN cal_evt_grp xg ON xg.event_grp_id = o.event_grp_id
JOIN res_grp mg ON mg.group_path = eg.group_path
               OR (o.inheritance_flag = 1
                   AND substr(mg.group_path, 1, length(eg.group_path) + 1) = eg.group_path || '/')
JOIN res_resgrp x ON x.res_grp_id = mg.res_grp_id
JOIN res r        ON r.res_id = x.res_id;

CREATE VIEW v_calndr_event AS
SELECT e.event_code, x.event_grp_code, e.cal_evt_type, g.group_path AS target, e.inheritance_flag,
       e.event_start_dt, e.event_start_tm, e.duration,
       e.active_start_dt, e.active_end_dt,
       e.days_of_week, e.months, e.month_end_flag, e.year, e.event_desc
FROM calndr_event e JOIN res_grp g ON g.res_grp_id = e.res_grp_id
LEFT JOIN cal_evt_grp x ON x.event_grp_id = e.event_grp_id;

-- Each metric sample with every calendar event in effect for its
-- resource on the sample's day. This is the join a decision layer
-- needs before it calls a change a signal: a price drop during a
-- promotion, or a gap during a maintenance window, has a known cause.
CREATE VIEW v_metric_sample_event AS
SELECT r.res_type, r.res_code, m.metric_code, p.provider_name,
       s.sample_utc_ts, s.value,
       c.event_code, c.event_grp_code, c.cal_evt_type
FROM metric_sample s
JOIN res r      ON r.res_id = s.res_id
JOIN metric m   ON m.metric_id = s.metric_id
JOIN provider p ON p.provider_id = s.provider_id
JOIN v_res_calendar c ON c.res_id = s.res_id AND c.occur_dt = date(s.sample_utc_ts);
