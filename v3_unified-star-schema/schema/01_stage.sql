-- =====================================================================
-- USS :: STAGE  (wide tables, BYTE-IDENTICAL files with DV/Kimball/Inmon/HOOK)
-- ---------------------------------------------------------------------
-- op / load_mode carry the shared delivery semantics:
--   >> ABSENCE means DELETE only for a FULL delivery. <<
--
-- Stage L2 dedups by recency and builds the change-compare string. Its
-- column names match the core tables exactly: that is the whole mapping
-- the generic core loader relies on.
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

-- The batch timestamp and the delivery id, so every core row can carry
-- its load_ts and record_source.
CREATE TABLE load_params (
    batch_ts TEXT NOT NULL,
    file_id  TEXT NOT NULL
);

-- Stage L2: recency dedup + change-compare string over RAW values.
-- Nothing is conformed on the way into the core; the USS refresh does it.
CREATE VIEW v_stg_customer_l2 AS
SELECT customer_id, full_name, email_addr, signup_date, extract_dt,
       COALESCE(TRIM(full_name),'')  || '|' ||
       COALESCE(TRIM(email_addr),'') || '|' ||
       COALESCE(TRIM(signup_date),'')      AS diff_str,
       op, load_mode
FROM (
  SELECT TRIM(customer_id) AS customer_id,
         full_name, email_addr, signup_date, extract_dt, op, load_mode,
         ROW_NUMBER() OVER (PARTITION BY TRIM(customer_id)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_customer_l1
) WHERE rn = 1;

CREATE VIEW v_stg_product_l2 AS
SELECT sku, prod_name, price, currency, extract_dt,
       COALESCE(TRIM(prod_name),'')           || '|' ||
       COALESCE(TRIM(CAST(price AS TEXT)),'') || '|' ||
       COALESCE(TRIM(currency),'')            AS diff_str,
       op, load_mode
FROM (
  SELECT TRIM(sku) AS sku,
         prod_name, price, currency, extract_dt, op, load_mode,
         ROW_NUMBER() OVER (PARTITION BY TRIM(sku)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_product_l1
) WHERE rn = 1;

-- customer_ref is part of the diff: a re-pointed order is a change like
-- any other and writes a new core row.
CREATE VIEW v_stg_order_l2 AS
SELECT order_ref, customer_ref, status, amount, currency, placed_at, extract_dt,
       COALESCE(customer_ref,'')                || '|' ||
       COALESCE(TRIM(status),'')               || '|' ||
       COALESCE(TRIM(CAST(amount AS TEXT)),'') || '|' ||
       COALESCE(TRIM(currency),'')             || '|' ||
       COALESCE(TRIM(placed_at),'')            AS diff_str,
       op, load_mode
FROM (
  SELECT TRIM(order_ref)    AS order_ref,
         TRIM(customer_ref) AS customer_ref,
         status, amount, currency, placed_at, extract_dt, op, load_mode,
         ROW_NUMBER() OVER (PARTITION BY TRIM(order_ref)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_order_l1
) WHERE rn = 1;

-- An order line is just the (order, sku) pair.
CREATE VIEW v_stg_order_line_l2 AS
SELECT order_ref, sku, extract_dt,
       ''                      AS diff_str,
       op, load_mode
FROM (
  SELECT TRIM(order_ref) AS order_ref,
         TRIM(sku)       AS sku,
         extract_dt, op, load_mode,
         ROW_NUMBER() OVER (PARTITION BY TRIM(order_ref), TRIM(sku)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_order_line_l1
) WHERE rn = 1;
