-- =====================================================================
-- USS :: THE CORE  (insert-only history under the presentation layer)
-- ---------------------------------------------------------------------
-- The Unified Star Schema (Francesco Puppini, with Bill Inmon) is a
-- PRESENTATION model: it says how to lay data out so that any user can
-- join anything to anything without fan traps or chasm traps. It says
-- little about history or loading. It expects to sit on top of a
-- warehouse.
--
-- So this leg has two tiers:
--   * the CORE (this file) -- one insert-only, delta-compressed history
--     table per source entity, natural keys, every change and every
--     delete a row. It never UPDATEs and never DELETEs.
--   * the USS (04_uss.sql) -- current-state tables plus the Puppini
--     bridge, fully re-derived from the core after every delivery.
--
-- Shared metadata on every core table:
--   extract_dt    source extract time (NULL on an absence-inferred delete)
--   change_type   INSERT | UPDATE | DELETE  (INSERT also = re-appearance)
--   delete_basis  TOMBSTONE | FULL_ABSENCE, set iff change_type='DELETE'
--   diff_str      change-compare string over the raw source attributes
--   load_ts       the batch timestamp that wrote the row
--   record_source the delivery (file_id) that wrote the row
-- =====================================================================

-- One row per core table: all the generic loader needs to load it.
--   table_key : the natural-key column(s) that identify a row's subject
CREATE TABLE core_table (
    core_table   TEXT PRIMARY KEY,
    load_order   INTEGER NOT NULL UNIQUE,
    stage_table  TEXT NOT NULL,
    stage_view   TEXT NOT NULL,
    table_key    TEXT NOT NULL
);
INSERT INTO core_table VALUES
 ('core_customer',   1, 'stg_customer_l1',   'v_stg_customer_l2',   'customer_id'),
 ('core_product',    2, 'stg_product_l1',    'v_stg_product_l2',    'sku'),
 ('core_order',      3, 'stg_order_l1',      'v_stg_order_l2',      'order_ref'),
 ('core_order_line', 4, 'stg_order_line_l1', 'v_stg_order_line_l2', 'order_ref,sku');

CREATE TABLE core_customer (
    customer_id   TEXT NOT NULL,
    full_name     TEXT,
    email_addr    TEXT,
    signup_date   TEXT,
    extract_dt    TEXT,
    change_type   TEXT NOT NULL CHECK (change_type IN ('INSERT','UPDATE','DELETE')),
    delete_basis  TEXT CHECK (delete_basis IN ('TOMBSTONE','FULL_ABSENCE')),
    diff_str      TEXT NOT NULL,
    load_ts       TEXT NOT NULL,
    record_source TEXT NOT NULL,
    CHECK ((change_type = 'DELETE') = (delete_basis IS NOT NULL)),
    PRIMARY KEY (customer_id, load_ts)
);

CREATE TABLE core_product (
    sku           TEXT NOT NULL,
    prod_name     TEXT,
    price         REAL,
    currency      TEXT,
    extract_dt    TEXT,
    change_type   TEXT NOT NULL CHECK (change_type IN ('INSERT','UPDATE','DELETE')),
    delete_basis  TEXT CHECK (delete_basis IN ('TOMBSTONE','FULL_ABSENCE')),
    diff_str      TEXT NOT NULL,
    load_ts       TEXT NOT NULL,
    record_source TEXT NOT NULL,
    CHECK ((change_type = 'DELETE') = (delete_basis IS NOT NULL)),
    PRIMARY KEY (sku, load_ts)
);

CREATE TABLE core_order (
    order_ref     TEXT NOT NULL,
    customer_ref  TEXT,
    status        TEXT,              -- RAW source code ('P'); decoded in the USS
    amount        REAL,
    currency      TEXT,
    placed_at     TEXT,
    extract_dt    TEXT,
    change_type   TEXT NOT NULL CHECK (change_type IN ('INSERT','UPDATE','DELETE')),
    delete_basis  TEXT CHECK (delete_basis IN ('TOMBSTONE','FULL_ABSENCE')),
    diff_str      TEXT NOT NULL,
    load_ts       TEXT NOT NULL,
    record_source TEXT NOT NULL,
    CHECK ((change_type = 'DELETE') = (delete_basis IS NOT NULL)),
    PRIMARY KEY (order_ref, load_ts)
);

CREATE TABLE core_order_line (
    order_ref     TEXT NOT NULL,
    sku           TEXT NOT NULL,
    extract_dt    TEXT,
    change_type   TEXT NOT NULL CHECK (change_type IN ('INSERT','UPDATE','DELETE')),
    delete_basis  TEXT CHECK (delete_basis IN ('TOMBSTONE','FULL_ABSENCE')),
    diff_str      TEXT NOT NULL,
    load_ts       TEXT NOT NULL,
    record_source TEXT NOT NULL,
    CHECK ((change_type = 'DELETE') = (delete_basis IS NOT NULL)),
    PRIMARY KEY (order_ref, sku, load_ts)
);

CREATE TRIGGER trg_cc_nu BEFORE UPDATE ON core_customer
BEGIN SELECT RAISE(ABORT,'core is insert-only'); END;
CREATE TRIGGER trg_cc_nd BEFORE DELETE ON core_customer
BEGIN SELECT RAISE(ABORT,'core is insert-only'); END;
CREATE TRIGGER trg_cp_nu BEFORE UPDATE ON core_product
BEGIN SELECT RAISE(ABORT,'core is insert-only'); END;
CREATE TRIGGER trg_cp_nd BEFORE DELETE ON core_product
BEGIN SELECT RAISE(ABORT,'core is insert-only'); END;
CREATE TRIGGER trg_co_nu BEFORE UPDATE ON core_order
BEGIN SELECT RAISE(ABORT,'core is insert-only'); END;
CREATE TRIGGER trg_co_nd BEFORE DELETE ON core_order
BEGIN SELECT RAISE(ABORT,'core is insert-only'); END;
CREATE TRIGGER trg_cl_nu BEFORE UPDATE ON core_order_line
BEGIN SELECT RAISE(ABORT,'core is insert-only'); END;
CREATE TRIGGER trg_cl_nd BEFORE DELETE ON core_order_line
BEGIN SELECT RAISE(ABORT,'core is insert-only'); END;

-- Latest row per subject. A DELETE row is a valid latest row.
CREATE VIEW v_latest__customer AS
SELECT * FROM (SELECT f.*, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY load_ts DESC) AS rn
               FROM core_customer f) WHERE rn = 1;
CREATE VIEW v_latest__product AS
SELECT * FROM (SELECT f.*, ROW_NUMBER() OVER (PARTITION BY sku ORDER BY load_ts DESC) AS rn
               FROM core_product f) WHERE rn = 1;
CREATE VIEW v_latest__order AS
SELECT * FROM (SELECT f.*, ROW_NUMBER() OVER (PARTITION BY order_ref ORDER BY load_ts DESC) AS rn
               FROM core_order f) WHERE rn = 1;
CREATE VIEW v_latest__order_line AS
SELECT * FROM (SELECT f.*, ROW_NUMBER() OVER (PARTITION BY order_ref, sku ORDER BY load_ts DESC) AS rn
               FROM core_order_line f) WHERE rn = 1;

-- Reference data for the status decode, applied by the USS refresh.
CREATE TABLE ref_order_status (
    status_code TEXT PRIMARY KEY,
    status_name TEXT NOT NULL
);
INSERT INTO ref_order_status VALUES
 ('P','PENDING'),('S','SHIPPED'),('D','DELIVERED'),('C','CANCELLED');
