-- =====================================================================
-- KIMBALL :: DIMENSIONS
-- ---------------------------------------------------------------------
-- Star-schema dimensions with surrogate keys. Two are SCD TYPE 2
-- (customer, product): a changed attribute EXPIRES the current row
-- (row_exp_ts, is_current=0 -- yes, an UPDATE; Kimball marts mutate,
-- unlike both insert-only demos next door) and inserts a new version.
--
-- Deletes ride the shared safety rule -- tombstone always, absence only
-- under FULL -- and land as an expired row plus a new CURRENT version
-- flagged is_deleted=1, carrying the last-known attributes. "Who was
-- C002?" stays answerable after the delete; dim rows are never removed
-- because facts point at them forever.
--
-- Surrogate keys are INTEGER PRIMARY KEY (rowid). Loader inserts carry
-- ORDER BY <business key>, and SQLite assigns rowids in that order, so
-- ordered PSA replay reproduces every surrogate key -- the same
-- determinism argument, and the same proof obligation, as the Focal
-- archive.
--
-- diff_str is the stored change-compare string ("hash differencing" in
-- Kimball ETL practice, plaintext here) -- same mechanism as the DV
-- demo's would-be hashdiff.
-- =====================================================================

CREATE TABLE dim_customer (
    customer_key INTEGER PRIMARY KEY,          -- surrogate (rowid)
    customer_ref TEXT NOT NULL,                -- business key
    customer_name TEXT,
    email        TEXT,
    signup_date  TEXT,
    diff_str     TEXT NOT NULL,
    row_eff_ts   TEXT NOT NULL,
    row_exp_ts   TEXT NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current   INTEGER NOT NULL DEFAULT 1,
    is_deleted   INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_dim_customer_bk ON dim_customer(customer_ref, is_current);

CREATE TABLE dim_product (
    product_key  INTEGER PRIMARY KEY,
    sku          TEXT NOT NULL,
    product_name TEXT,
    price        REAL,
    currency     TEXT,
    diff_str     TEXT NOT NULL,
    row_eff_ts   TEXT NOT NULL,
    row_exp_ts   TEXT NOT NULL DEFAULT '9999-12-31 23:59:59',
    is_current   INTEGER NOT NULL DEFAULT 1,
    is_deleted   INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX ix_dim_product_bk ON dim_product(sku, is_current);

-- ------------------------- DIM_DATE (generated) -----------------------
-- The signature Kimball dimension: one row per calendar day, smart key
-- YYYYMMDD. Generated once at init; no loader ever touches it.
CREATE TABLE dim_date (
    date_key   INTEGER PRIMARY KEY,            -- 20260201
    full_date  TEXT NOT NULL,                  -- 2026-02-01
    year       INTEGER NOT NULL,
    month      INTEGER NOT NULL,
    month_name TEXT NOT NULL,
    day        INTEGER NOT NULL,
    weekday    TEXT NOT NULL
);
INSERT INTO dim_date
WITH RECURSIVE d(dt) AS (
  SELECT DATE('2026-01-01')
  UNION ALL SELECT DATE(dt,'+1 day') FROM d WHERE dt < '2027-12-31'
)
SELECT CAST(STRFTIME('%Y%m%d',dt) AS INTEGER), dt,
       CAST(STRFTIME('%Y',dt) AS INTEGER),
       CAST(STRFTIME('%m',dt) AS INTEGER),
       CASE STRFTIME('%m',dt) WHEN '01' THEN 'January' WHEN '02' THEN 'February'
         WHEN '03' THEN 'March' WHEN '04' THEN 'April' WHEN '05' THEN 'May'
         WHEN '06' THEN 'June' WHEN '07' THEN 'July' WHEN '08' THEN 'August'
         WHEN '09' THEN 'September' WHEN '10' THEN 'October'
         WHEN '11' THEN 'November' ELSE 'December' END,
       CAST(STRFTIME('%d',dt) AS INTEGER),
       CASE STRFTIME('%w',dt) WHEN '0' THEN 'Sunday' WHEN '1' THEN 'Monday'
         WHEN '2' THEN 'Tuesday' WHEN '3' THEN 'Wednesday' WHEN '4' THEN 'Thursday'
         WHEN '5' THEN 'Friday' ELSE 'Saturday' END
FROM d;

-- --------------------- DIM_ORDER_STATUS (decode) ----------------------
-- The P->PENDING translation as a SEEDED DIMENSION rather than ingest
-- logic: the fact stores the raw source code's key; the label lives
-- here. Change a label and every fact -- past and future -- reads the
-- new one; and because the PSA retains the raw codes, `make rebuild`
-- re-derives cleanly if the mapping itself is restructured.
CREATE TABLE dim_order_status (
    status_key  INTEGER PRIMARY KEY,
    status_code TEXT NOT NULL UNIQUE,           -- raw source value
    status_name TEXT NOT NULL
);
INSERT INTO dim_order_status(status_key, status_code, status_name) VALUES
 (1,'P','PENDING'),
 (2,'S','SHIPPED'),
 (3,'D','DELIVERED'),
 (4,'C','CANCELLED');

-- --------------------------- current views ----------------------------
CREATE VIEW v_dim_customer_current AS
SELECT * FROM dim_customer WHERE is_current=1;
CREATE VIEW v_dim_product_current AS
SELECT * FROM dim_product  WHERE is_current=1;
