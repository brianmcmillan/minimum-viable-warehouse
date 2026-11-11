-- =====================================================================
-- ACTIVITY SCHEMA :: THE READ MODEL  (every answer is a stream query)
-- ---------------------------------------------------------------------
-- No foreign keys anywhere. Activities relate to each other by WHO
-- (customer), WHAT (link) and WHEN (ts) -- the spec's temporal
-- relationships:
--   LAST EVER     current state                    (v_*_state, 03_activity.sql)
--   LAST BEFORE   the value as it stood at a moment (v_order_at_purchase)
--   FIRST EVER    a customer's first order          (v_customer_journey)
--   FIRST AFTER   what happened next                (v_customer_journey)
-- The status decode is a soft rule applied ON READ.
-- =====================================================================

---------------------------- business views ----------------------------
-- Column-for-column with the sibling demos' business views.

CREATE VIEW v_customer AS
SELECT customer_id AS customer_ref, full_name AS customer_name,
       email_addr AS email, signup_date
FROM v_customer_state WHERE alive = 1;

CREATE VIEW v_product AS
SELECT sku, prod_name AS product_name, price, currency
FROM v_product_state WHERE alive = 1;

-- placed_by: the order's CURRENT owner, if that customer is still alive.
CREATE VIEW v_order AS
SELECT o.order_ref,
       COALESCE(r.status_name, 'UNKNOWN(' || COALESCE(o.status,'') || ')') AS status,
       o.amount, o.currency, o.placed_at,
       c.full_name AS placed_by
FROM v_order_state o
LEFT JOIN ref_oms_order_status r ON r.status_code = o.status
LEFT JOIN v_customer_state c ON c.customer_id = o.customer_ref AND c.alive = 1
WHERE o.alive = 1;

CREATE VIEW v_order_line AS
SELECT order_ref, sku FROM v_order_line_state WHERE on_order = 1;

------------------------- temporal relationships -------------------------
-- A profile value as it stood at a moment: the newest profile activity
-- for that customer strictly BEFORE the moment (spec: LAST BEFORE).
-- Used by the views below; never a stored column.
CREATE VIEW v_customer_profile_assertion AS
SELECT s.customer, s.ts, s._seq, j.key AS attr, j.value AS val
FROM customer_stream s, json_each(s.feature_json) j
WHERE s.activity IN ('signed_up','restored','updated_name','updated_email','updated_signup_date');

-- LAST BEFORE: cohort = placed_order; appended = the placing customer's
-- name and email as they were when the order was placed. Kimball gets
-- this from a frozen surrogate key; here it is a temporal join on ts.
CREATE VIEW v_order_at_purchase AS
SELECT po.link AS order_ref, po.ts AS placed_at, po.customer AS customer_ref,
       (SELECT a.val FROM v_customer_profile_assertion a
         WHERE a.customer = po.customer AND a.attr = 'full_name' AND a.ts < po.ts
         ORDER BY a.ts DESC, a._seq DESC LIMIT 1) AS placed_by_at_purchase,
       (SELECT a.val FROM v_customer_profile_assertion a
         WHERE a.customer = po.customer AND a.attr = 'email_addr' AND a.ts < po.ts
         ORDER BY a.ts DESC, a._seq DESC LIMIT 1) AS email_at_purchase,
       vo.placed_by AS placed_by_current
FROM customer_stream po
LEFT JOIN v_order vo ON vo.order_ref = po.link
WHERE po.activity = 'placed_order';

-- Ownership history (the D6 re-point): every activity that put an order
-- in a customer's stream, read against its own moment -- the owner's
-- name LAST BEFORE (or at) that ts, NULL if the owner was deleted then.
CREATE VIEW v_order_ownership AS
SELECT s.link AS order_ref, s.ts AS recorded_at, s.activity, s.customer AS owner,
       CASE WHEN (SELECT l.activity FROM customer_stream l
                   WHERE l.customer = s.customer AND l.ts <= s.ts
                     AND l.activity IN ('signed_up','restored','was_deleted')
                   ORDER BY l.ts DESC, l._seq DESC LIMIT 1) = 'was_deleted' THEN NULL
            ELSE (SELECT a.val FROM v_customer_profile_assertion a
                   WHERE a.customer = s.customer AND a.attr = 'full_name' AND a.ts <= s.ts
                   ORDER BY a.ts DESC, a._seq DESC LIMIT 1) END AS owner_name_then
FROM customer_stream s
WHERE s.activity IN ('placed_order','order_reassigned','order_restored');

-- A behavioural question, the model's home ground. Cohort = signed_up;
-- FIRST EVER placed_order; FIRST AFTER that order, the next email change;
-- and an aggregate over the stream. Deleted customers included: history
-- does not stop being true when a customer is deleted.
CREATE VIEW v_customer_journey AS
SELECT su.customer AS customer_ref,
       su.ts AS signed_up_at,
       fo.first_order_at,
       CAST(julianday(fo.first_order_at) - julianday(su.ts) AS INTEGER) AS days_to_first_order,
       (SELECT MIN(e.ts) FROM customer_stream e
         WHERE e.customer = su.customer AND e.activity = 'updated_email'
           AND e.ts > fo.first_order_at) AS email_changed_after_first_order,
       (SELECT COUNT(*) FROM customer_stream o
         WHERE o.customer = su.customer AND o.activity = 'placed_order') AS orders_placed
FROM customer_stream su
LEFT JOIN (SELECT customer, MIN(ts) AS first_order_at FROM customer_stream
           WHERE activity = 'placed_order' GROUP BY customer) fo ON fo.customer = su.customer
WHERE su.activity = 'signed_up';

------------------------------ lineage views ------------------------------
CREATE VIEW v_customer_history AS
SELECT customer AS customer_ref, ts, activity, link, feature_json,
       _load_ts AS load_ts, _record_source AS record_source
FROM customer_stream ORDER BY customer, ts, _seq;

CREATE VIEW v_product_history AS
SELECT customer AS sku, ts, activity, link, feature_json,
       _load_ts AS load_ts, _record_source AS record_source
FROM product_stream ORDER BY customer, ts, _seq;
