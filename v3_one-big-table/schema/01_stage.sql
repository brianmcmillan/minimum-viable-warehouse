-- =====================================================================
-- OBT :: STAGE  (wide tables, BYTE-IDENTICAL files with DV/Kimball/Inmon)
-- ---------------------------------------------------------------------
-- Stage exists only as the file-ingest surface: rows land here, are
-- appended verbatim to the archive, and the stage is cleared. There is
-- no stage-2, no delta engine, no merge -- the "model" is a full
-- recomputation over the log (see refresh_latest.sh).
-- =====================================================================

CREATE TABLE stg_customer_l1 (
    customer_id  TEXT NOT NULL,
    full_name    TEXT,
    email_addr   TEXT,
    signup_date  TEXT,
    extract_dt   TEXT NOT NULL,
    op           TEXT NOT NULL DEFAULT 'UPSERT',
    load_mode    TEXT NOT NULL
);
CREATE TABLE stg_product_l1 (
    sku          TEXT NOT NULL,
    prod_name    TEXT,
    price        REAL,
    currency     TEXT,
    extract_dt   TEXT NOT NULL,
    op           TEXT NOT NULL DEFAULT 'UPSERT',
    load_mode    TEXT NOT NULL
);
CREATE TABLE stg_order_l1 (
    order_ref    TEXT NOT NULL,
    customer_ref TEXT,
    status       TEXT,
    amount       REAL,
    currency     TEXT,
    placed_at    TEXT,
    extract_dt   TEXT NOT NULL,
    op           TEXT NOT NULL DEFAULT 'UPSERT',
    load_mode    TEXT NOT NULL
);
CREATE TABLE stg_order_line_l1 (
    order_ref    TEXT NOT NULL,
    sku          TEXT NOT NULL,
    extract_dt   TEXT NOT NULL,
    op           TEXT NOT NULL DEFAULT 'UPSERT',
    load_mode    TEXT NOT NULL
);

-- =====================================================================
-- The derived layer: latest-state tables, fully recomputed from the
-- archive on every load (the dbt-style full-refresh / functional data
-- engineering pattern -- idempotent by construction, no incremental
-- state anywhere). obt_order_wide is the pattern's namesake: one big
-- denormalized table at order-line grain.
-- =====================================================================

CREATE TABLE obt_customer (
    customer_ref TEXT PRIMARY KEY,
    full_name    TEXT,
    email        TEXT,
    signup_date  TEXT
);
CREATE TABLE obt_product (
    sku          TEXT PRIMARY KEY,
    product_name TEXT,
    price        REAL,
    currency     TEXT
);
CREATE TABLE obt_orders (
    order_ref    TEXT PRIMARY KEY,
    customer_ref TEXT,
    status       TEXT,               -- RAW source code; translation is on read
    amount       REAL,
    currency     TEXT,
    placed_at    TEXT
);
CREATE TABLE obt_order_lines (
    order_ref TEXT NOT NULL,
    sku       TEXT NOT NULL,
    PRIMARY KEY (order_ref, sku)
);

-- The One Big Table: order-line grain, everything denormalized.
CREATE TABLE obt_order_wide (
    order_ref     TEXT NOT NULL,
    placed_at     TEXT,
    status        TEXT,
    amount        REAL,
    currency      TEXT,
    customer_ref  TEXT,
    customer_name TEXT,
    email         TEXT,
    sku           TEXT NOT NULL,
    product_name  TEXT,
    price         REAL,
    PRIMARY KEY (order_ref, sku)
);

------------------------------- views ----------------------------------
-- Business views mirroring the sibling demos. Note where the P->PENDING
-- rule lives: in the VIEW. In OBT practice every consumer either
-- re-implements this CASE or shares a view like this one -- there is no
-- model layer to state it once.

CREATE VIEW v_customer AS
SELECT customer_ref, full_name AS customer_name, email, signup_date FROM obt_customer;

CREATE VIEW v_product AS
SELECT sku, product_name, price, currency FROM obt_product;

CREATE VIEW v_order AS
SELECT o.order_ref,
       CASE o.status WHEN 'P' THEN 'PENDING'  WHEN 'S' THEN 'SHIPPED'
                     WHEN 'D' THEN 'DELIVERED' WHEN 'C' THEN 'CANCELLED'
                     ELSE o.status END AS status,
       o.amount, o.currency, o.placed_at,
       (SELECT c.full_name FROM obt_customer c
         WHERE c.customer_ref = o.customer_ref) AS placed_by
FROM obt_orders o;
