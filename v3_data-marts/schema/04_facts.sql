-- =====================================================================
-- KIMBALL :: FACTS + BUSINESS-FACING VIEWS
-- ---------------------------------------------------------------------
-- fact_orders: one row per order (transaction grain). order_ref is the
-- degenerate dimension. customer_key is FROZEN at load time: it points
-- to the SCD2 version that was current when the fact arrived, and a
-- later change to the customer creates a new dim version WITHOUT
-- touching the fact. That is the Kimball point-in-time mechanism --
-- history lives in the dimension, the fact just holds the right key.
--
-- Facts ARE updated in place when the source restates an order
-- (amount, status, or a re-pointed customer): the only one of the three
-- demos that mutates a row. The PSA is what makes that defensible --
-- every prior state is still in psa_order, and `make rebuild` reapplies
-- the whole history.
--
-- fact_order_lines: factless fact at order x product grain.
-- =====================================================================

CREATE TABLE fact_orders (
    order_ref      TEXT NOT NULL,               -- degenerate dimension
    placed_date_key INTEGER NOT NULL REFERENCES dim_date(date_key),
    customer_key   INTEGER NOT NULL REFERENCES dim_customer(customer_key),
    status_key     INTEGER NOT NULL REFERENCES dim_order_status(status_key),
    amount         REAL,
    currency       TEXT,
    placed_at      TEXT,                        -- full timestamp (beyond day grain)
    PRIMARY KEY (order_ref)
);

CREATE TABLE fact_order_lines (
    order_ref   TEXT NOT NULL,
    product_key INTEGER NOT NULL REFERENCES dim_product(product_key),
    placed_date_key INTEGER NOT NULL REFERENCES dim_date(date_key),
    PRIMARY KEY (order_ref, product_key)
);

-- ------------------- comparison views (cross-demo) --------------------
-- Same output columns as Focal's v_customer / v_product / v_order and
-- the DV demo's dim_/fact_ views, so `make demo` compares directly.

CREATE VIEW mart_customers AS
SELECT customer_ref, customer_name, email, signup_date
FROM v_dim_customer_current WHERE is_deleted=0;

CREATE VIEW mart_products AS
SELECT sku, product_name, price, currency
FROM v_dim_product_current WHERE is_deleted=0;

-- Two placed_by columns, because the star can answer both questions:
--   placed_by_at_purchase -- via the FROZEN surrogate key in the fact
--   placed_by_current     -- via the business key, current version,
--                            NULL once the customer is deleted (this is
--                            the column that matches the other demos)
CREATE VIEW mart_orders AS
SELECT f.order_ref,
       st.status_name AS status,
       f.amount, f.currency, f.placed_at,
       (SELECT c.customer_name FROM dim_customer c
         WHERE c.customer_key = f.customer_key)          AS placed_by_at_purchase,
       (SELECT c.customer_name FROM dim_customer c
         WHERE c.customer_ref = (SELECT customer_ref FROM dim_customer
                                 WHERE customer_key = f.customer_key)
           AND c.is_current=1 AND c.is_deleted=0)        AS placed_by_current
FROM fact_orders f
JOIN dim_order_status st ON st.status_key = f.status_key;

-- SCD2 timeline: every version of every customer, with validity window.
CREATE VIEW v_customer_history AS
SELECT customer_key, customer_ref, customer_name, email,
       row_eff_ts, row_exp_ts, is_current, is_deleted
FROM dim_customer ORDER BY customer_ref, row_eff_ts;

-- The star, joined: one line per order line with all dimensions decoded.
CREATE VIEW v_star_order_lines AS
SELECT l.order_ref, d.full_date AS placed_date, p.product_name, p.price,
       f.amount AS order_amount, st.status_name AS order_status
FROM fact_order_lines l
JOIN dim_date d        ON d.date_key = l.placed_date_key
JOIN dim_product p     ON p.product_key = l.product_key
JOIN fact_orders f     ON f.order_ref = l.order_ref
JOIN dim_order_status st ON st.status_key = f.status_key;
