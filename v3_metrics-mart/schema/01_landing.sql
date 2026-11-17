-- =====================================================================
-- METRICS MART :: WIDE STAGE + NARROW LANDING + ROUTING METADATA
-- ---------------------------------------------------------------------
-- Deliveries arrive WIDE, one row per record, in the stg_*_l1 tables --
-- the same files and DDL as every other model. That is what load control
-- compares and what the archive keeps. scripts/stage_narrow.sh (the same
-- script Focal and Anchor use) unpivots them into the narrow landing,
-- which is BYTE-IDENTICAL to the Focal and Anchor demos': the same
-- source_landing_stage / source_landing pair. Each narrow row is one
-- attribute assertion:
--   (source_system, source_entity, business_key, attribute_name, value)
-- which is already the shape of the mart's own METRIC_STG:
--   (provider_name, res_type, res_alias, metric_code, value)
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

-- Wide staging: a delivery file lands here first (same DDL as every
-- other model).
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
-- route_stage.sh reads measurements from here, pre-dedup.
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
-- ROUTING METADATA. The Focal/Anchor idea, pointed at a 3NF target: two
-- small maps decide where each narrow row goes. Nothing in the loaders
-- names a feed or an attribute.
-- ---------------------------------------------------------------------

-- One row per feed.
--   role = RES    : each business key is a resource of res_type
--   role = MEMBER : each business key is a group membership; the group
--                   is group_root || '/' || <group_attribute value> and
--                   the member is the resource named by member_attribute
CREATE TABLE meta_feed_map (
    source_system    TEXT NOT NULL,
    source_entity    TEXT NOT NULL,
    role             TEXT NOT NULL CHECK (role IN ('RES','MEMBER')),
    res_type         TEXT,
    group_root       TEXT,
    group_attribute  TEXT,
    member_attribute TEXT,
    member_res_type  TEXT,
    PRIMARY KEY (source_system, source_entity)
);

-- One row per narrow attribute.
--   KEY     : the business key restated; ignored
--   RES_COL : a column of RES itself (target_col)
--   SUBTYPE : a column of a subtype table (target_table.target_col), read
--             from `slot`; ref_table names a code table, ref_open=1 lets
--             the load add new codes, ref_open=0 makes the domain closed
--   PARENT  : the alias of this resource's parent, of parent_res_type
--   METRIC  : a numeric measurement, routed to METRIC_STG as metric_code
CREATE TABLE meta_attribute_map (
    source_system    TEXT NOT NULL,
    source_entity    TEXT NOT NULL,
    source_attribute TEXT NOT NULL,
    target_kind      TEXT NOT NULL CHECK (target_kind IN ('KEY','RES_COL','SUBTYPE','PARENT','METRIC')),
    target_table     TEXT,
    target_col       TEXT,
    slot             TEXT,            -- value_str | value_num | value_ts
    ref_table        TEXT,
    ref_col          TEXT,
    ref_open         INTEGER,
    parent_res_type  TEXT,
    metric_code      TEXT,
    PRIMARY KEY (source_system, source_entity, source_attribute)
);

-- Loader guard: a rule that must hold before a load step commits. The
-- CHECK turns a non-zero violation count into a failed statement, which
-- rolls the step back.
CREATE TABLE load_guard (
    rule       TEXT NOT NULL,
    violations INTEGER NOT NULL CHECK (violations = 0)
);
