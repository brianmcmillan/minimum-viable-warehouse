-- =====================================================================
-- METRICS MART :: NARROW LANDING + ROUTING METADATA
-- ---------------------------------------------------------------------
-- The landing is BYTE-IDENTICAL to the Focal and Anchor demos': the same
-- source_landing_stage / source_landing pair, consuming the same narrow
-- delivery files. Each staged row is one attribute assertion:
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

-- Staging: a delivery file lands here first; the driver then recency-
-- dedupes it into source_landing.
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
--   role = EVENT  : each business key is a calendar event (event_code)
CREATE TABLE meta_feed_map (
    source_system    TEXT NOT NULL,
    source_entity    TEXT NOT NULL,
    role             TEXT NOT NULL CHECK (role IN ('RES','MEMBER','EVENT')),
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
--   EVENT_COL : a column of CALNDR_EVENT_STG (target_col), read from `slot`
CREATE TABLE meta_attribute_map (
    source_system    TEXT NOT NULL,
    source_entity    TEXT NOT NULL,
    source_attribute TEXT NOT NULL,
    target_kind      TEXT NOT NULL CHECK (target_kind IN ('KEY','RES_COL','SUBTYPE','PARENT','METRIC','EVENT_COL')),
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
