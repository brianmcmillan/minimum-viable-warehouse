-- =====================================================================
-- HOOK :: THE WAREHOUSE  (frames + the hook registry)
-- ---------------------------------------------------------------------
-- HOOK (Andrew Foad) keeps the warehouse as close to the sources as it
-- can get and does exactly one modeling act: it HOOKS every source row
-- to the Core Business Concepts it is about.
--
--   * CORE BUSINESS CONCEPT (CBC) -- a business noun: CUSTOMER, PRODUCT,
--     ORDER. A CBC is an entry in a glossary, NOT a table. There is no
--     hub, no anchor, no dimension.
--   * KEY SET -- the namespace a business key belongs to, usually "which
--     system minted it": CRM.CUST, PIM.SKU, OMS.ORD. Two keys only
--     integrate when they share a key set.
--   * HOOK -- '<key set>|<business key>', e.g. 'CRM.CUST|C001', stored as
--     an extra hk_<concept> column on the source row. A row can carry
--     several hooks; that is how relationships exist -- no link tables.
--   * FRAME -- one per source table: the source columns VERBATIM, the
--     hooks, and load metadata. Insert-only, delta-compressed (an
--     unchanged restatement writes nothing). Named frame__<src>__<table>.
--
-- Everything business-shaped -- decodes, current state, point-in-time,
-- "the customer" as a thing -- is a VIEW over frames (see 04_views.sql).
-- Frames never UPDATE and never DELETE: deletes are frame rows too.
-- =====================================================================

------------------------------ the registry ------------------------------
-- The registry is the model. It is also what the generic frame loader
-- (scripts/load_frames.sh) and the hook-integrity tests read.

CREATE TABLE hook_concept (
    concept     TEXT PRIMARY KEY,
    description TEXT NOT NULL
);
INSERT INTO hook_concept VALUES
 ('CUSTOMER','a party that places orders'),
 ('PRODUCT', 'something we sell'),
 ('ORDER',   'a customer''s request to buy products');

CREATE TABLE hook_keyset (
    keyset        TEXT PRIMARY KEY,
    concept       TEXT NOT NULL REFERENCES hook_concept(concept),
    source_system TEXT NOT NULL,
    description   TEXT NOT NULL
);
INSERT INTO hook_keyset VALUES
 ('CRM.CUST','CUSTOMER','CRM','customer number minted by the CRM'),
 ('PIM.SKU', 'PRODUCT', 'PIM','stock keeping unit minted by the PIM'),
 ('OMS.ORD', 'ORDER',   'OMS','order reference minted by the OMS');

-- One row per frame. The loader needs nothing else to load it.
--   frame_key  : the hook column(s) that identify a frame row's subject
--   bk_columns : source columns carried onto a DELETE row (the rest NULL)
CREATE TABLE hook_frame (
    frame        TEXT PRIMARY KEY,
    load_order   INTEGER NOT NULL UNIQUE,
    stage_table  TEXT NOT NULL,
    stage_view   TEXT NOT NULL,
    frame_key    TEXT NOT NULL,
    bk_columns   TEXT NOT NULL,
    description  TEXT NOT NULL
);
INSERT INTO hook_frame VALUES
 ('frame__crm__customer',   1,'stg_customer_l1',  'v_stg_customer_l2',
  'hk_customer',            'customer_id',  'CRM customer master'),
 ('frame__pim__product',    2,'stg_product_l1',   'v_stg_product_l2',
  'hk_product',             'sku',          'PIM product catalogue'),
 ('frame__oms__order',      3,'stg_order_l1',     'v_stg_order_l2',
  'hk_order',               'order_ref',    'OMS order header'),
 ('frame__oms__order_line', 4,'stg_order_line_l1','v_stg_order_line_l2',
  'hk_order,hk_product',    'order_ref,sku','OMS order line (order x product)');

-- Every hook column on every frame, and the key set its values must use.
CREATE TABLE hook_column (
    frame       TEXT NOT NULL REFERENCES hook_frame(frame),
    hook_column TEXT NOT NULL,
    keyset      TEXT NOT NULL REFERENCES hook_keyset(keyset),
    PRIMARY KEY (frame, hook_column)
);
INSERT INTO hook_column VALUES
 ('frame__crm__customer',  'hk_customer','CRM.CUST'),
 ('frame__pim__product',   'hk_product', 'PIM.SKU'),
 ('frame__oms__order',     'hk_order',   'OMS.ORD'),
 ('frame__oms__order',     'hk_customer','CRM.CUST'),
 ('frame__oms__order_line','hk_order',   'OMS.ORD'),
 ('frame__oms__order_line','hk_product', 'PIM.SKU');

------------------------------- the frames -------------------------------
-- Shared metadata on every frame:
--   extract_dt    source extract time (NULL on an absence-inferred delete)
--   change_type   INSERT | UPDATE | DELETE  (INSERT also = re-appearance)
--   delete_basis  TOMBSTONE | FULL_ABSENCE, set iff change_type='DELETE'
--   diff_str      change-compare string over the raw source attributes
--   load_ts       the batch timestamp that wrote the row
--   record_source the delivery (file_id) that wrote the row

CREATE TABLE frame__crm__customer (
    hk_customer   TEXT NOT NULL,
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
    PRIMARY KEY (hk_customer, load_ts)
);

CREATE TABLE frame__pim__product (
    hk_product    TEXT NOT NULL,
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
    PRIMARY KEY (hk_product, load_ts)
);

-- Two hooks: hk_order identifies the row's subject, hk_customer points
-- at another CBC. The relationship lives on the row that asserts it.
CREATE TABLE frame__oms__order (
    hk_order      TEXT NOT NULL,
    hk_customer   TEXT,
    order_ref     TEXT NOT NULL,
    customer_ref  TEXT,
    status        TEXT,              -- RAW source code ('P'), decoded on read
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
    PRIMARY KEY (hk_order, load_ts)
);

CREATE TABLE frame__oms__order_line (
    hk_order      TEXT NOT NULL,
    hk_product    TEXT NOT NULL,
    order_ref     TEXT NOT NULL,
    sku           TEXT NOT NULL,
    extract_dt    TEXT,
    change_type   TEXT NOT NULL CHECK (change_type IN ('INSERT','UPDATE','DELETE')),
    delete_basis  TEXT CHECK (delete_basis IN ('TOMBSTONE','FULL_ABSENCE')),
    diff_str      TEXT NOT NULL,
    load_ts       TEXT NOT NULL,
    record_source TEXT NOT NULL,
    CHECK ((change_type = 'DELETE') = (delete_basis IS NOT NULL)),
    PRIMARY KEY (hk_order, hk_product, load_ts)
);

-- Frames are insert-only. Unlike the archive this database is disposable
-- (make rebuild), but within its life no row is ever rewritten.
CREATE TRIGGER trg_fc_nu BEFORE UPDATE ON frame__crm__customer
BEGIN SELECT RAISE(ABORT,'frames are insert-only'); END;
CREATE TRIGGER trg_fc_nd BEFORE DELETE ON frame__crm__customer
BEGIN SELECT RAISE(ABORT,'frames are insert-only'); END;
CREATE TRIGGER trg_fp_nu BEFORE UPDATE ON frame__pim__product
BEGIN SELECT RAISE(ABORT,'frames are insert-only'); END;
CREATE TRIGGER trg_fp_nd BEFORE DELETE ON frame__pim__product
BEGIN SELECT RAISE(ABORT,'frames are insert-only'); END;
CREATE TRIGGER trg_fo_nu BEFORE UPDATE ON frame__oms__order
BEGIN SELECT RAISE(ABORT,'frames are insert-only'); END;
CREATE TRIGGER trg_fo_nd BEFORE DELETE ON frame__oms__order
BEGIN SELECT RAISE(ABORT,'frames are insert-only'); END;
CREATE TRIGGER trg_fl_nu BEFORE UPDATE ON frame__oms__order_line
BEGIN SELECT RAISE(ABORT,'frames are insert-only'); END;
CREATE TRIGGER trg_fl_nd BEFORE DELETE ON frame__oms__order_line
BEGIN SELECT RAISE(ABORT,'frames are insert-only'); END;

-- Reference data for the soft rule, applied ON READ (04_views.sql).
-- Changing a label here changes every query immediately, with no reload.
CREATE TABLE ref_oms_order_status (
    status_code TEXT PRIMARY KEY,
    status_name TEXT NOT NULL
);
INSERT INTO ref_oms_order_status VALUES
 ('P','PENDING'),('S','SHIPPED'),('D','DELIVERED'),('C','CANCELLED');
