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

-- ---- History: RES_HIST -------------------------------------------------
-- The version a live resource has right now: its descriptive columns
-- (RES and its subtype row) and its parent. load_res.sh compares RES_HIST's
-- open version with this to decide whether to close it and open a new one.
CREATE VIEW v_res_snapshot AS
SELECT r.res_id, r.res_name, r.res_short_name, r.res_desc, r.parent_res,
       c.email_addr, c.signup_date,
       COALESCE(p.currency_code, o.currency_code) AS currency_code,
       o.status_code, o.placed_at
FROM res r
LEFT JOIN res_customer c ON c.res_id = r.res_id
LEFT JOIN res_product  p ON p.res_id = r.res_id
LEFT JOIN res_order    o ON o.res_id = r.res_id
WHERE r.res_status = 1;

-- Every version of every resource, with its validity window. A resource as
-- at a timestamp :ts is the row with valid_from <= :ts AND :ts < valid_to
-- (an open version's valid_to reads as the end of time).
CREATE VIEW v_res_version AS
SELECT h.res_id, r.res_type, r.res_code,
       h.valid_from, COALESCE(h.valid_to, '9999-12-31 23:59:59') AS valid_to,
       CASE WHEN h.valid_to IS NULL THEN 1 ELSE 0 END AS is_open, h.batch_no,
       h.res_name, h.res_short_name, h.res_desc,
       h.parent_res, (SELECT x.res_code FROM res x WHERE x.res_id = h.parent_res) AS parent_code,
       h.email_addr, h.signup_date, h.currency_code, h.status_code, h.placed_at
FROM res_hist h JOIN res r ON r.res_id = h.res_id;

-- Who placed each order, as at purchase: the parent of the order's first
-- version, named by that customer's version valid when the order was
-- first recorded. A re-point opens a new order version and leaves this one.
CREATE VIEW v_order_at_purchase AS
SELECT f.res_code AS order_ref, f.valid_from AS recorded_at,
       f.parent_code AS customer_ref,
       (SELECT c.res_name FROM v_res_version c
         WHERE c.res_id = f.parent_res
           AND c.valid_from <= f.valid_from AND f.valid_from < c.valid_to) AS placed_by_at_purchase
FROM v_res_version f
WHERE f.res_type = 'ORDER'
  AND f.valid_from = (SELECT MIN(x.valid_from) FROM res_hist x WHERE x.res_id = f.res_id);

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

-- Every sample. A sample is a value first seen or changed: first seen is
-- sample_utc_ts, last seen is the latest time the same value came again.
CREATE VIEW v_metric_sample AS
SELECT r.res_type, r.res_code, m.metric_code, p.provider_name,
       s.sample_utc_ts, s.value,
       s.sample_utc_ts AS first_seen_utc_ts, s.last_seen_utc_ts
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
