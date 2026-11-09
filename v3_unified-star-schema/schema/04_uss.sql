-- =====================================================================
-- USS :: THE UNIFIED STAR SCHEMA  (presentation layer)
-- ---------------------------------------------------------------------
-- Puppini's idea: put ONE table in the middle, the BRIDGE, and make
-- every other table a point on the star.
--
--   * Every table keeps its columns but loses its foreign keys. It gets
--     one key of its own: _key_<table>.
--   * The _bridge is a UNION ALL of "stages", one per table. A stage
--     row carries that table's key PLUS the keys of everything the row
--     reaches through many-to-one paths (an order line reaches its
--     order, its product, and -- through the order -- its customer).
--   * Measures live on the bridge, ON THEIR OWN STAGE ONLY. The order
--     amount sits on the 'Orders' row and is NULL on the 'Order line'
--     rows, so joining lines can never repeat it (no FAN TRAP).
--   * Every table gets its own stage, so a customer with no orders still
--     has a bridge row and still shows up (no CHASM TRAP).
--   * Every join is bridge -> table, LEFT, on one key. A user can drag
--     any column from any table into one query and get a correct answer.
--
-- These tables are DERIVED: scripts/refresh_uss.sh rebuilds them from
-- the core after every delivery. They are the one place in this leg
-- where rows get deleted, and nothing is lost when they are, because
-- the core underneath is insert-only.
-- =====================================================================

CREATE TABLE customer (
    _key_customer TEXT PRIMARY KEY,
    customer_ref  TEXT NOT NULL,
    customer_name TEXT,
    email         TEXT,
    signup_date   TEXT
);

CREATE TABLE product (
    _key_product TEXT PRIMARY KEY,
    sku          TEXT NOT NULL,
    product_name TEXT,
    price        REAL,
    currency     TEXT
);

-- No customer_ref here: in a USS the relationship lives on the bridge.
CREATE TABLE orders (
    _key_orders  TEXT PRIMARY KEY,
    order_ref    TEXT NOT NULL,
    status       TEXT,     -- decoded at refresh
    status_code  TEXT,     -- raw source code, kept for lineage
    amount       REAL,
    currency     TEXT,
    placed_at    TEXT
);

CREATE TABLE order_line (
    _key_order_line TEXT PRIMARY KEY,   -- order_ref|sku
    order_ref       TEXT NOT NULL,
    sku             TEXT NOT NULL
);

CREATE TABLE _bridge (
    stage           TEXT NOT NULL CHECK (stage IN ('Customer','Product','Orders','Order line')),
    _key_customer   TEXT,
    _key_product    TEXT,
    _key_orders     TEXT,
    _key_order_line TEXT,
    order_amount    REAL,      -- set on 'Orders' rows only
    line_count      INTEGER    -- set on 'Order line' rows only
);

-- When the USS was last derived, and from which core state.
CREATE TABLE uss_refresh (
    refreshed_for_load_ts TEXT NOT NULL,
    record_source         TEXT NOT NULL
);

------------------------------- views ----------------------------------
-- Every business view reads FROM _bridge and LEFT JOINs the tables it
-- needs. Column-for-column with the sibling demos where they overlap.

CREATE VIEW v_customer AS
SELECT customer_ref, customer_name, email, signup_date FROM customer;

CREATE VIEW v_product AS
SELECT sku, product_name, price, currency FROM product;

CREATE VIEW v_order AS
SELECT o.order_ref, o.status, o.amount, o.currency, o.placed_at,
       c.customer_name AS placed_by
FROM _bridge b
JOIN orders o        ON o._key_orders   = b._key_orders
LEFT JOIN customer c ON c._key_customer = b._key_customer
WHERE b.stage = 'Orders';

-- The view a self-service user would build by dragging fields: customer
-- name, order amount, and line count in ONE query. Each measure is
-- summed from its own stage, so nothing is double counted, and the
-- Customer stage keeps order-less customers in the result.
CREATE VIEW v_sales_by_customer AS
SELECT b._key_customer                      AS customer_ref,
       MAX(c.customer_name)                 AS customer_name,
       COUNT(DISTINCT b._key_orders)        AS n_orders,
       COALESCE(ROUND(SUM(b.order_amount), 2), 0) AS order_amount,
       COALESCE(SUM(b.line_count), 0)       AS n_lines
FROM _bridge b
LEFT JOIN customer c ON c._key_customer = b._key_customer
WHERE b._key_customer IS NOT NULL
GROUP BY b._key_customer;

-- Per product: the line measure only. The order amount lives at order
-- grain; the bridge refuses to invent an allocation to products.
CREATE VIEW v_sales_by_product AS
SELECT b._key_product                       AS sku,
       MAX(p.product_name)                  AS product_name,
       COUNT(DISTINCT b._key_orders)        AS n_orders,
       COALESCE(SUM(b.line_count), 0)       AS n_lines
FROM _bridge b
LEFT JOIN product p ON p._key_product = b._key_product
WHERE b._key_product IS NOT NULL
GROUP BY b._key_product;

-- The FAN TRAP, side by side. The naive query joins orders to their
-- lines and sums the order amount: an order with two lines counts twice.
-- The bridge query sums the same amount from the 'Orders' stage only.
CREATE VIEW v_fan_trap AS
SELECT
  (SELECT ROUND(SUM(o.amount), 2)
     FROM v_latest__order o
     JOIN v_latest__order_line l ON l.order_ref = o.order_ref
    WHERE o.change_type <> 'DELETE' AND l.change_type <> 'DELETE')   AS naive_join_total,
  (SELECT ROUND(SUM(order_amount), 2) FROM _bridge)                 AS bridge_total,
  (SELECT ROUND(SUM(amount), 2) FROM orders)                        AS true_total;

----------------------------- history ----------------------------------
-- The USS is current state; history is read from the core underneath.

-- Point-in-time: each core order row with the customer row that was
-- latest when the order row was loaded.
CREATE VIEW v_order_as_recorded AS
SELECT o.order_ref, o.load_ts AS recorded_at,
       COALESCE(r.status_name, 'UNKNOWN(' || COALESCE(o.status,'') || ')') AS status,
       o.amount,
       (SELECT CASE WHEN c.change_type = 'DELETE' THEN NULL ELSE c.full_name END
          FROM core_customer c
         WHERE c.customer_id = o.customer_ref AND c.load_ts <= o.load_ts
         ORDER BY c.load_ts DESC LIMIT 1) AS placed_by_as_recorded
FROM core_order o
LEFT JOIN ref_order_status r ON r.status_code = o.status
WHERE o.change_type <> 'DELETE';

CREATE VIEW v_customer_history AS
SELECT customer_id AS customer_ref, full_name, email_addr AS email,
       change_type, delete_basis, load_ts, record_source
FROM core_customer ORDER BY customer_ref, load_ts;
