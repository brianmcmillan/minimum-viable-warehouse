-- =====================================================================
-- ACTIVITY SCHEMA :: STAGE  (wide tables, BYTE-IDENTICAL delivery files
-- with DV/Kimball/Inmon/HOOK/USS/OBT)
-- ---------------------------------------------------------------------
-- op / load_mode carry the shared delivery semantics:
--   >> ABSENCE means DELETE only for a FULL delivery. <<
--
-- Deliveries are STATE snapshots ("C001's email is X"), not events. The
-- loader turns the difference between a delivery and the state already
-- implied by the streams into activities. Stage L2 does only the shared
-- recency dedup; there is no hashing, no diff string and no key
-- construction -- change detection compares values against the streams.
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

-- The batch timestamp and the delivery id, so every activity carries
-- its _load_ts and _record_source (spec: `_` columns are
-- implementation-specific).
CREATE TABLE act_load_params (
    batch_ts TEXT NOT NULL,
    file_id  TEXT NOT NULL
);

-- Stage L2: recency dedup -- one row per subject per delivery, newest
-- extract_dt wins, staged order (rowid) breaks ties. Values stay raw.
CREATE VIEW v_stg_customer_l2 AS
SELECT customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode
FROM (
  SELECT TRIM(customer_id) AS customer_id,
         full_name, email_addr, signup_date, extract_dt, op, load_mode,
         ROW_NUMBER() OVER (PARTITION BY TRIM(customer_id)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_customer_l1
) WHERE rn = 1;

CREATE VIEW v_stg_product_l2 AS
SELECT sku, prod_name, price, currency, extract_dt, op, load_mode
FROM (
  SELECT TRIM(sku) AS sku,
         prod_name, price, currency, extract_dt, op, load_mode,
         ROW_NUMBER() OVER (PARTITION BY TRIM(sku)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_product_l1
) WHERE rn = 1;

CREATE VIEW v_stg_order_l2 AS
SELECT order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode
FROM (
  SELECT TRIM(order_ref)    AS order_ref,
         TRIM(customer_ref) AS customer_ref,
         status, amount, currency, placed_at, extract_dt, op, load_mode,
         ROW_NUMBER() OVER (PARTITION BY TRIM(order_ref)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_order_l1
) WHERE rn = 1;

CREATE VIEW v_stg_order_line_l2 AS
SELECT order_ref, sku, extract_dt, op, load_mode
FROM (
  SELECT TRIM(order_ref) AS order_ref,
         TRIM(sku)       AS sku,
         extract_dt, op, load_mode,
         ROW_NUMBER() OVER (PARTITION BY TRIM(order_ref), TRIM(sku)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_order_line_l1
) WHERE rn = 1;
