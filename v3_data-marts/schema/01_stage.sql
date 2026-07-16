-- =====================================================================
-- KIMBALL :: STAGE LEVEL 1  (one wide table per source feed)
-- ---------------------------------------------------------------------
-- BYTE-IDENTICAL delivery files are shared with the v3_datavault demo:
-- the same stg_*_l1 tables, the same D0-D5 files, so every difference
-- between the three warehouses is the model, never the input.
--
-- op / load_mode carry the shared delivery semantics:
--   op        = UPSERT | DELETE (tombstone)
--   load_mode = FULL | INCREMENTAL
--   >> ABSENCE means DELETE only for a FULL delivery. <<
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

-- One-row parameter table: the logical load timestamp of the delivery
-- being processed. Set by the driver; read by the stage-2 views.
CREATE TABLE mart_load_params (
    batch_ts TEXT NOT NULL
);

-- =====================================================================
-- STAGE LEVEL 2 (views): recency dedup + change-compare string.
-- diff_str is the Kimball ETL "hash differencing" column, in plaintext:
-- comparing it against the current dimension row's stored diff_str is
-- the entire SCD2 change-detection mechanism.
-- =====================================================================

CREATE VIEW v_stg_customer_l2 AS
SELECT ldts, customer_bk, full_name, email_addr, signup_date,
       COALESCE(TRIM(full_name),'')  || '|' ||
       COALESCE(TRIM(email_addr),'') || '|' ||
       COALESCE(TRIM(signup_date),'')      AS diff_str,
       op, load_mode, extract_dt
FROM (
  SELECT (SELECT batch_ts FROM mart_load_params) AS ldts,
         TRIM(customer_id) AS customer_bk,
         full_name, email_addr, signup_date, op, load_mode, extract_dt,
         ROW_NUMBER() OVER (PARTITION BY TRIM(customer_id)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_customer_l1
) WHERE rn = 1;

CREATE VIEW v_stg_product_l2 AS
SELECT ldts, product_bk, prod_name, price, currency,
       COALESCE(TRIM(prod_name),'')           || '|' ||
       COALESCE(TRIM(CAST(price AS TEXT)),'') || '|' ||
       COALESCE(TRIM(currency),'')            AS diff_str,
       op, load_mode, extract_dt
FROM (
  SELECT (SELECT batch_ts FROM mart_load_params) AS ldts,
         TRIM(sku) AS product_bk,
         prod_name, price, currency, op, load_mode, extract_dt,
         ROW_NUMBER() OVER (PARTITION BY TRIM(sku)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_product_l1
) WHERE rn = 1;

CREATE VIEW v_stg_order_l2 AS
SELECT ldts, order_bk, customer_bk, status, amount, currency, placed_at,
       op, load_mode, extract_dt
FROM (
  SELECT (SELECT batch_ts FROM mart_load_params) AS ldts,
         TRIM(order_ref)    AS order_bk,
         TRIM(customer_ref) AS customer_bk,
         status, amount, currency, placed_at, op, load_mode, extract_dt,
         ROW_NUMBER() OVER (PARTITION BY TRIM(order_ref)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_order_l1
) WHERE rn = 1;

CREATE VIEW v_stg_order_line_l2 AS
SELECT ldts, order_bk, product_bk, op, load_mode, extract_dt
FROM (
  SELECT (SELECT batch_ts FROM mart_load_params) AS ldts,
         TRIM(order_ref) AS order_bk,
         TRIM(sku)       AS product_bk,
         op, load_mode, extract_dt,
         ROW_NUMBER() OVER (PARTITION BY TRIM(order_ref), TRIM(sku)
                            ORDER BY extract_dt DESC, rowid DESC) AS rn
  FROM stg_order_line_l1
) WHERE rn = 1;
