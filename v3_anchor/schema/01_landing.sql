-- =====================================================================
-- ANCHOR :: LANDING + LOADER METADATA
-- ---------------------------------------------------------------------
-- Deliveries arrive WIDE, one row per record, in the stg_*_l1 tables --
-- the same files and the same DDL as every wide-shape sibling. That is
-- what load control compares and what the archive keeps.
-- scripts/stage_narrow.sh then unpivots them into the narrow (key-value)
-- source_landing_stage / source_landing pair, which is byte-identical to
-- the Focal demo's. Anchor loading is inherently per-attribute, and the
-- narrow landing is at attribute grain -- each narrow row IS one attribute
-- assertion.
--
-- op / load_mode carry the shared delivery semantics:
--   op        = UPSERT | DELETE (tombstone)
--   load_mode = FULL | INCREMENTAL
--   >> ABSENCE means DELETE only for a FULL delivery. <<
-- =====================================================================

-- Landing = the CURRENT delivery per feed (per-feed replace on load).
CREATE TABLE source_landing (
    source_system  TEXT NOT NULL,
    source_entity  TEXT NOT NULL,
    business_key   TEXT NOT NULL,
    attribute_name TEXT NOT NULL,
    value_str      TEXT,
    value_num      REAL,
    value_ts       TEXT,
    extract_ts     TEXT NOT NULL,
    op             TEXT NOT NULL DEFAULT 'UPSERT',
    load_mode      TEXT
);
CREATE INDEX ix_landing ON source_landing(source_system, source_entity, attribute_name);

-- Wide staging: a delivery file lands here first (same DDL as the
-- wide-shape siblings).
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

-- Narrow staging: stage_narrow.sh unpivots the wide stage into key/value
-- rows here; the driver then recency-dedupes it into source_landing.
CREATE TABLE source_landing_stage (
    source_system  TEXT NOT NULL,
    source_entity  TEXT NOT NULL,
    business_key   TEXT NOT NULL,
    attribute_name TEXT NOT NULL,
    value_str      TEXT,
    value_num      REAL,
    value_ts       TEXT,
    extract_ts     TEXT NOT NULL,
    op             TEXT NOT NULL DEFAULT 'UPSERT',
    load_mode      TEXT
);

-- ---------------------------------------------------------------------
-- LOADER METADATA. Anchor ships no ETL doctrine (the official tool
-- generates DDL and insert triggers, not pipeline discipline), so the
-- loading strategy here is the one shared by all four demos, driven --
-- as in the Focal demo -- by small metadata maps rather than per-table
-- scripts. The difference from Focal: each map row targets a REAL,
-- individually typed attribute table instead of a type_key row in a
-- generic one.
-- ---------------------------------------------------------------------

-- One row per anchor: which feed keys it, and where its business-key
-- attribute (the *_REF static attribute) lives.
CREATE TABLE meta_anchor_map (
    anchor_mn     TEXT PRIMARY KEY,   -- CU | PR | OD  (OD, not OR: bare OR is a SQL keyword)
    anchor_table  TEXT NOT NULL,
    id_col        TEXT NOT NULL,
    ref_table     TEXT NOT NULL,      -- static attribute holding the business key
    ref_col       TEXT NOT NULL,
    est_table     TEXT NOT NULL,      -- knotted existence attribute (presence)
    source_system TEXT NOT NULL,
    source_entity TEXT NOT NULL,
    key_attribute TEXT NOT NULL       -- attribute_name carrying the business key
);

-- One row per descriptive attribute: narrow feed attribute -> its own
-- typed table. slot names the narrow column the value travels in;
-- historized=1 adds ChangedAt versioning; knot_* resolve a code to a
-- knot surrogate at load.
CREATE TABLE meta_attribute_map (
    source_system    TEXT NOT NULL,
    source_entity    TEXT NOT NULL,
    source_attribute TEXT NOT NULL,
    anchor_mn        TEXT NOT NULL REFERENCES meta_anchor_map(anchor_mn),
    attr_table       TEXT NOT NULL,
    attr_col         TEXT NOT NULL,
    slot             TEXT NOT NULL,   -- value_str | value_num | value_ts
    historized       INTEGER NOT NULL DEFAULT 0,
    knot_table       TEXT,            -- set when the attribute is knotted
    knot_id_col      TEXT,
    knot_val_col     TEXT,
    PRIMARY KEY (source_system, source_entity, source_attribute)
);

-- One row per tie: both roles resolve business keys through the ref
-- attributes; historized=1 means latest-per-driving-role wins (the
-- driving role is the FIRST one).
CREATE TABLE meta_tie_map (
    tie_table     TEXT PRIMARY KEY,
    historized    INTEGER NOT NULL DEFAULT 0,
    source_system TEXT NOT NULL,
    source_entity TEXT NOT NULL,
    src_anchor_mn TEXT NOT NULL REFERENCES meta_anchor_map(anchor_mn),
    src_attribute TEXT NOT NULL,      -- narrow attribute carrying the driving key
    src_id_col    TEXT NOT NULL,
    tgt_anchor_mn TEXT NOT NULL REFERENCES meta_anchor_map(anchor_mn),
    tgt_attribute TEXT NOT NULL,
    tgt_id_col    TEXT NOT NULL
);
