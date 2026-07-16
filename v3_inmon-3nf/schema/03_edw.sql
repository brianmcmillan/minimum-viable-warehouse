-- =====================================================================
-- INMON :: THE TIME-VARIANT 3NF EDW
-- ---------------------------------------------------------------------
-- The control group. Subject-oriented, integrated, time-variant,
-- non-volatile -- Inmon's four adjectives -- rendered the classic way:
--
--   * NATURAL KEYS. customer_ref IS the key; orders reference it as a
--     plain foreign key. No surrogates, no hubs, no anchors.
--   * TIME-VARIANT ROWS. Every entity row carries valid_from/valid_to;
--     a change CLOSES the current row (an UPDATE) and inserts a new
--     one. One table holds current and history together.
--   * INTEGRATED = CONFORMED AT INGEST. The EDW stores 'PENDING', not
--     'P' -- cleansing happens on the way in, via the normalized
--     reference table below. The raw 'P' survives only in the archive
--     (which is what makes the conformance rule retroactively fixable
--     via `make rebuild`; classic CIF had no such recourse).
--   * deletes: close + insert an is_deleted marker row carrying the
--     last-known attributes, same shared safety rule as every sibling.
--
-- What this design does NOT give you -- and the suite makes visible:
-- point-in-time questions need RANGE joins (see v_order_as_recorded's
-- BETWEEN gymnastics, vs Kimball's frozen-key equi-join), and schema
-- evolution is ALTER TABLE on populated history tables.
-- diff_str is the loader's change-compare helper (raw source values).
-- =====================================================================

CREATE TABLE customer (
    customer_ref TEXT NOT NULL,
    full_name    TEXT,
    email        TEXT,
    signup_date  TEXT,
    diff_str     TEXT NOT NULL,
    valid_from   TEXT NOT NULL,
    valid_to     TEXT NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current   INTEGER NOT NULL DEFAULT 1,
    is_deleted   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (customer_ref, valid_from)
);

CREATE TABLE product (
    sku          TEXT NOT NULL,
    product_name TEXT,
    price        REAL,
    currency     TEXT,
    diff_str     TEXT NOT NULL,
    valid_from   TEXT NOT NULL,
    valid_to     TEXT NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current   INTEGER NOT NULL DEFAULT 1,
    is_deleted   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (sku, valid_from)
);

CREATE TABLE orders (
    order_ref    TEXT NOT NULL,
    customer_ref TEXT,                 -- natural-key FK: the 3NF relationship
    status       TEXT,                 -- CONFORMED value ('PENDING'), not the raw code
    amount       REAL,
    currency     TEXT,
    placed_at    TEXT,
    diff_str     TEXT NOT NULL,
    valid_from   TEXT NOT NULL,
    valid_to     TEXT NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current   INTEGER NOT NULL DEFAULT 1,
    is_deleted   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (order_ref, valid_from)
);

CREATE TABLE order_line (              -- static association, insert-if-absent
    order_ref  TEXT NOT NULL,
    sku        TEXT NOT NULL,
    valid_from TEXT NOT NULL,
    PRIMARY KEY (order_ref, sku)
);

-- Normalized reference data: the conformance rule, applied AT INGEST.
CREATE TABLE order_status_ref (
    status_code TEXT PRIMARY KEY,
    status_name TEXT NOT NULL
);
INSERT INTO order_status_ref VALUES
 ('P','PENDING'),('S','SHIPPED'),('D','DELIVERED'),('C','CANCELLED');

------------------------------- views ----------------------------------
-- Current-state views mirroring the sibling demos' business views.

CREATE VIEW v_customer AS
SELECT customer_ref, full_name AS customer_name, email, signup_date
FROM customer WHERE is_current=1 AND is_deleted=0;

CREATE VIEW v_product AS
SELECT sku, product_name, price, currency
FROM product WHERE is_current=1 AND is_deleted=0;

CREATE VIEW v_order AS
SELECT o.order_ref, o.status, o.amount, o.currency, o.placed_at,
       (SELECT c.full_name FROM customer c
         WHERE c.customer_ref = o.customer_ref
           AND c.is_current=1 AND c.is_deleted=0) AS placed_by
FROM orders o WHERE o.is_current=1 AND o.is_deleted=0;

-- Point-in-time, the 3NF way: a RANGE join against the customer's
-- validity window as of the moment the EDW recorded the order version.
-- This is what a frozen surrogate key (Kimball) or a computed latest
-- (Anchor/DV) replaces with an equi-join.
CREATE VIEW v_order_as_recorded AS
SELECT o.order_ref, o.valid_from AS recorded_at, o.status, o.amount,
       c.full_name AS placed_by_as_recorded
FROM orders o
LEFT JOIN customer c
       ON c.customer_ref = o.customer_ref
      AND o.valid_from >= c.valid_from
      AND o.valid_from <  c.valid_to;

CREATE VIEW v_customer_history AS
SELECT customer_ref, full_name, email, valid_from, valid_to, is_current, is_deleted
FROM customer ORDER BY customer_ref, valid_from;
