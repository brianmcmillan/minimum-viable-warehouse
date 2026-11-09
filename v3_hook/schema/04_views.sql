-- =====================================================================
-- HOOK :: THE READ MODEL  (everything business-shaped is a view)
-- ---------------------------------------------------------------------
-- Frames hold what the sources said. These views decide what it means:
--   * latest-row views turn delta frames into current state
--   * hooks are the join keys -- equi-joins, across frames, no bridge
--   * the status decode is a soft rule applied ON READ
--   * a "hub" is a GROUP BY over hook occurrences, not a table
-- =====================================================================

------------------------------ latest rows ------------------------------
-- The newest frame row per subject. A DELETE row is a perfectly good
-- latest row: it is what makes deleted subjects vanish from the business
-- views below without any is_current flag to maintain.

CREATE VIEW v_latest__crm__customer AS
SELECT * FROM (
  SELECT f.*, ROW_NUMBER() OVER (PARTITION BY hk_customer ORDER BY load_ts DESC) AS rn
  FROM frame__crm__customer f) WHERE rn = 1;

CREATE VIEW v_latest__pim__product AS
SELECT * FROM (
  SELECT f.*, ROW_NUMBER() OVER (PARTITION BY hk_product ORDER BY load_ts DESC) AS rn
  FROM frame__pim__product f) WHERE rn = 1;

CREATE VIEW v_latest__oms__order AS
SELECT * FROM (
  SELECT f.*, ROW_NUMBER() OVER (PARTITION BY hk_order ORDER BY load_ts DESC) AS rn
  FROM frame__oms__order f) WHERE rn = 1;

CREATE VIEW v_latest__oms__order_line AS
SELECT * FROM (
  SELECT f.*, ROW_NUMBER() OVER (PARTITION BY hk_order, hk_product ORDER BY load_ts DESC) AS rn
  FROM frame__oms__order_line f) WHERE rn = 1;

---------------------------- business views ----------------------------
-- Column-for-column with the sibling demos' business views.

CREATE VIEW v_customer AS
SELECT customer_id AS customer_ref, full_name AS customer_name,
       email_addr AS email, signup_date
FROM v_latest__crm__customer WHERE change_type <> 'DELETE';

CREATE VIEW v_product AS
SELECT sku, prod_name AS product_name, price, currency
FROM v_latest__pim__product WHERE change_type <> 'DELETE';

-- placed_by: the order's hk_customer equi-joins the customer frame's
-- hk_customer. Same key set, same value -- that is the whole integration.
CREATE VIEW v_order AS
SELECT o.order_ref,
       COALESCE(r.status_name, 'UNKNOWN(' || COALESCE(o.status,'') || ')') AS status,
       o.amount, o.currency, o.placed_at,
       c.full_name AS placed_by
FROM v_latest__oms__order o
LEFT JOIN ref_oms_order_status r ON r.status_code = o.status
LEFT JOIN v_latest__crm__customer c
       ON c.hk_customer = o.hk_customer AND c.change_type <> 'DELETE'
WHERE o.change_type <> 'DELETE';

CREATE VIEW v_order_line AS
SELECT order_ref, sku
FROM v_latest__oms__order_line WHERE change_type <> 'DELETE';

-- Point-in-time: for every order frame row, the customer frame row that
-- was latest when the order row was loaded. One hook equality plus an
-- as-of ordering -- no validity windows, because frames never close rows.
CREATE VIEW v_order_as_recorded AS
SELECT o.order_ref, o.load_ts AS recorded_at,
       COALESCE(r.status_name, 'UNKNOWN(' || COALESCE(o.status,'') || ')') AS status,
       o.amount,
       (SELECT CASE WHEN c.change_type = 'DELETE' THEN NULL ELSE c.full_name END
          FROM frame__crm__customer c
         WHERE c.hk_customer = o.hk_customer AND c.load_ts <= o.load_ts
         ORDER BY c.load_ts DESC LIMIT 1) AS placed_by_as_recorded
FROM frame__oms__order o
LEFT JOIN ref_oms_order_status r ON r.status_code = o.status
WHERE o.change_type <> 'DELETE';

CREATE VIEW v_customer_history AS
SELECT customer_id AS customer_ref, full_name, email_addr AS email,
       change_type, delete_basis, load_ts, record_source
FROM frame__crm__customer ORDER BY customer_ref, load_ts;

------------------------- hooks across frames --------------------------
-- Every hook value on every frame row. Kept in step with hook_column by
-- the test suite (a hook column missing here fails it).
CREATE VIEW v_hook_occurrence AS
          SELECT 'frame__crm__customer'   AS frame, 'hk_customer' AS hook_column, hk_customer AS hook, load_ts FROM frame__crm__customer
UNION ALL SELECT 'frame__pim__product',             'hk_product',                 hk_product,          load_ts FROM frame__pim__product
UNION ALL SELECT 'frame__oms__order',               'hk_order',                   hk_order,            load_ts FROM frame__oms__order
UNION ALL SELECT 'frame__oms__order',               'hk_customer',                hk_customer,         load_ts FROM frame__oms__order WHERE hk_customer IS NOT NULL
UNION ALL SELECT 'frame__oms__order_line',          'hk_order',                   hk_order,            load_ts FROM frame__oms__order_line
UNION ALL SELECT 'frame__oms__order_line',          'hk_product',                 hk_product,          load_ts FROM frame__oms__order_line;

-- The "hub on demand": one row per distinct member of each concept, and
-- the frames that mention it. Data Vault materialises this as a table
-- every loader must write first; HOOK derives it when someone asks.
CREATE VIEW v_concept_member AS
SELECT k.concept,
       h.hook,
       substr(h.hook, instr(h.hook, '|') + 1)            AS business_key,
       MIN(h.load_ts)                                   AS first_seen,
       COUNT(DISTINCT h.frame)                          AS n_frames,
       group_concat(DISTINCT h.frame)                   AS frames
FROM v_hook_occurrence h
JOIN hook_keyset k ON k.keyset = substr(h.hook, 1, instr(h.hook, '|') - 1)
GROUP BY k.concept, h.hook;

-- Hook integrity: any hook whose key-set prefix is unregistered, or is
-- not the key set the registry declares for that frame column. Must be
-- empty; the test suite asserts it after every delivery.
CREATE VIEW v_hook_violation AS
SELECT h.frame, h.hook_column, h.hook, c.keyset AS expected_keyset
FROM v_hook_occurrence h
LEFT JOIN hook_column c ON c.frame = h.frame AND c.hook_column = h.hook_column
WHERE c.keyset IS NULL
   OR instr(h.hook, '|') = 0
   OR substr(h.hook, 1, instr(h.hook, '|') - 1) <> c.keyset
   OR substr(h.hook, instr(h.hook, '|') + 1) = '';
