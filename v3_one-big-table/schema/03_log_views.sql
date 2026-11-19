-- =====================================================================
-- HISTORY AS VIEWS OVER THE LOG.  TEMP views; needs the archive attached
-- as `arch`.
-- ---------------------------------------------------------------------
-- The log is archive/obt_archive.db. A view stored in build/obt.db may
-- not read an attached database, and the log is not copied into obt.db,
-- so these are TEMP views: each connection that wants history loads this
-- file after attaching the archive. scripts/query.sh does, and so does
-- every answer file that reads history (tests/answers/Q2, Q3, Q4, Q7),
-- with `.read v3_one-big-table/schema/03_log_views.sql` -- a path from
-- the repo root, where `make compare` and the suite run them.
--
-- A delivery applies one row per key: the newest extract_dt, then the
-- last in the file -- the same recency rule refresh_latest.sh uses. A
-- version is an applied UPSERT whose values differ from the one before
-- (LAG over a NULL-safe quote() of the values). valid_from is the batch
-- timestamp of the delivery that brought it; valid_to is the next
-- version's valid_from (NULL: still the latest value). When a customer
-- went is v_customer_gone, not valid_to.
-- =====================================================================

-- The row each delivery applied, per customer and per product.
CREATE TEMP VIEW v_customer_applied AS
SELECT customer_id, full_name, email_addr, signup_date, op, load_mode, load_seq, batch_ts
FROM (SELECT h.*, ROW_NUMBER() OVER (PARTITION BY customer_id, load_seq
                                     ORDER BY extract_dt DESC, seq_nbr DESC) AS rn
      FROM arch.hist_customer h)
WHERE rn = 1;

CREATE TEMP VIEW v_product_applied AS
SELECT sku, prod_name, price, currency, op, load_mode, load_seq, batch_ts
FROM (SELECT h.*, ROW_NUMBER() OVER (PARTITION BY sku, load_seq
                                     ORDER BY extract_dt DESC, seq_nbr DESC) AS rn
      FROM arch.hist_product h)
WHERE rn = 1;

-- Every version of each customer: only values that differ from the one before.
CREATE TEMP VIEW v_customer_version AS
WITH d AS (
  SELECT customer_id, full_name, email_addr, signup_date, load_seq, batch_ts,
         quote(full_name)||'|'||quote(email_addr)||'|'||quote(signup_date) AS diff,
         LAG(quote(full_name)||'|'||quote(email_addr)||'|'||quote(signup_date))
           OVER (PARTITION BY customer_id ORDER BY load_seq) AS prev_diff
  FROM v_customer_applied WHERE op = 'UPSERT'),
v AS (SELECT * FROM d
WHERE prev_diff IS NULL OR diff IS NOT prev_diff)
SELECT customer_id, full_name, email_addr, signup_date,
       batch_ts AS valid_from,
       LEAD(batch_ts) OVER (PARTITION BY customer_id ORDER BY load_seq) AS valid_to,
       load_seq
FROM v;

-- Every version of each product: the same rule.
CREATE TEMP VIEW v_product_version AS
WITH d AS (
  SELECT sku, prod_name, price, currency, load_seq, batch_ts,
         quote(prod_name)||'|'||quote(price)||'|'||quote(currency) AS diff,
         LAG(quote(prod_name)||'|'||quote(price)||'|'||quote(currency))
           OVER (PARTITION BY sku ORDER BY load_seq) AS prev_diff
  FROM v_product_applied WHERE op = 'UPSERT'),
v AS (SELECT * FROM d
WHERE prev_diff IS NULL OR diff IS NOT prev_diff)
SELECT sku, prod_name, price, currency,
       batch_ts AS valid_from,
       LEAD(batch_ts) OVER (PARTITION BY sku ORDER BY load_seq) AS valid_to,
       load_seq
FROM v;

-- Every customer the log has seen that the latest table no longer holds,
-- and when it went: the first delivery after its last applied UPSERT
-- that tombstoned it or was a FULL customer snapshot (one without it --
-- had it been there, that would be its last UPSERT).
CREATE TEMP VIEW v_customer_gone AS
SELECT s.customer_id,
       (SELECT MIN(a.batch_ts) FROM v_customer_applied a
         WHERE a.load_seq > COALESCE(s.last_up, 0)
           AND ((a.customer_id = s.customer_id AND a.op = 'DELETE') OR a.load_mode = 'FULL')) AS went_at
FROM (SELECT customer_id, MAX(CASE WHEN op = 'UPSERT' THEN load_seq END) AS last_up
      FROM v_customer_applied GROUP BY customer_id) s
WHERE s.customer_id NOT IN (SELECT customer_ref FROM main.obt_customer);

-- Each order's first owner, with that owner's attributes as at the same
-- delivery: the order's first logged row, and the customer version in
-- force at that delivery ("as first recorded").
CREATE TEMP VIEW v_order_first_owner AS
WITH o AS (
  SELECT order_ref, customer_ref, load_seq, batch_ts FROM (
    SELECT order_ref, customer_ref, load_seq, batch_ts,
           ROW_NUMBER() OVER (PARTITION BY order_ref ORDER BY load_seq, seq_nbr) AS rn
    FROM arch.hist_order) WHERE rn = 1)
SELECT o.order_ref, o.customer_ref, o.batch_ts AS first_seen,
       c.full_name, c.email_addr, c.signup_date
FROM o LEFT JOIN v_customer_version c
  ON c.customer_id = o.customer_ref
 AND c.load_seq = (SELECT MAX(x.load_seq) FROM v_customer_version x
                   WHERE x.customer_id = o.customer_ref AND x.load_seq <= o.load_seq);
