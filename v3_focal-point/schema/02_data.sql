-- =====================================================================
-- FOCAL FRAMEWORK :: DATA LAYER (the four generic table types)
-- ---------------------------------------------------------------------
-- These tables are intentionally generic. On their own they are almost
-- meaningless -- a row says "entity 1002, type_key 30, val_num 59.9,
-- uom USD". Meaning comes ONLY by joining type_key back to the metadata.
--
-- Per entity there are three tables: _idfr, _focal, _desc.
-- Per relationship there is one _x table.
-- The COLUMN SHAPE never changes when you add business attributes --
-- new attributes are new ROWS (new type_key), never new columns.
-- =====================================================================

-- Shared audit columns on every physical table:
--   data_key      pipeline-isolation key (scopes delta comparison)
--   inst_key      which pipeline execution wrote the row (-> meta_procinst)
--   inst_row_key  pipeline-template id
--   popln_tmstp   when the row was physically written

------------------------------- CUSTOMER -------------------------------
-- 1) IDFR : maps every business identifier to a stable surrogate key.
CREATE TABLE customer_idfr (
    customer_idfr TEXT    NOT NULL,   -- business identifier (as seen in source)
    eff_tmstp     TEXT    NOT NULL,   -- when this identifier became effective
    ver_tmstp     TEXT    NOT NULL,   -- version (bi-temporal tie-breaker)
    row_st        TEXT    NOT NULL,   -- Y active / N retired
    customer_key  INTEGER NOT NULL,   -- the surrogate key
    data_key      INTEGER NOT NULL,
    inst_key      INTEGER NOT NULL,
    inst_row_key  INTEGER NOT NULL,
    popln_tmstp   TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (customer_idfr, eff_tmstp, ver_tmstp)
);

-- 2) FOCAL : exactly one authoritative row per surrogate key.
CREATE TABLE customer_focal (
    customer_key INTEGER NOT NULL,
    eff_tmstp    TEXT    NOT NULL,
    ver_tmstp    TEXT    NOT NULL,
    row_st       TEXT    NOT NULL,
    data_key     INTEGER NOT NULL,
    inst_key     INTEGER NOT NULL,
    inst_row_key INTEGER NOT NULL,
    popln_tmstp  TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (customer_key)
);

-- 3) DESC : all descriptive attributes, one row per atomic context per
--    version. Generic value columns are filled per the metadata map.
CREATE TABLE customer_desc (
    customer_key INTEGER NOT NULL,
    type_key     INTEGER NOT NULL,   -- <-- the semantic key
    eff_tmstp    TEXT    NOT NULL,
    ver_tmstp    TEXT    NOT NULL,
    seq_nbr      INTEGER NOT NULL DEFAULT 0,
    row_st       TEXT    NOT NULL,   -- Y active / N logically deleted
    sta_tmstp    TEXT,               -- generic: start/from date-time
    end_tmstp    TEXT,               -- generic: end/to date-time
    val_str      TEXT,               -- generic: string value
    val_num      REAL,               -- generic: numeric value
    uom          TEXT,               -- generic: unit of measure / qualifier
    data_key     INTEGER NOT NULL,
    inst_key     INTEGER NOT NULL,
    inst_row_key INTEGER NOT NULL,
    popln_tmstp  TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (customer_key, type_key, eff_tmstp, ver_tmstp)
);

------------------------------- PRODUCT --------------------------------
CREATE TABLE product_idfr (
    product_idfr TEXT NOT NULL, eff_tmstp TEXT NOT NULL, ver_tmstp TEXT NOT NULL,
    row_st TEXT NOT NULL, product_key INTEGER NOT NULL,
    data_key INTEGER NOT NULL, inst_key INTEGER NOT NULL, inst_row_key INTEGER NOT NULL,
    popln_tmstp TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (product_idfr, eff_tmstp, ver_tmstp)
);
CREATE TABLE product_focal (
    product_key INTEGER NOT NULL, eff_tmstp TEXT NOT NULL, ver_tmstp TEXT NOT NULL,
    row_st TEXT NOT NULL, data_key INTEGER NOT NULL, inst_key INTEGER NOT NULL,
    inst_row_key INTEGER NOT NULL, popln_tmstp TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (product_key)
);
CREATE TABLE product_desc (
    product_key INTEGER NOT NULL, type_key INTEGER NOT NULL, eff_tmstp TEXT NOT NULL,
    ver_tmstp TEXT NOT NULL, seq_nbr INTEGER NOT NULL DEFAULT 0, row_st TEXT NOT NULL,
    sta_tmstp TEXT, end_tmstp TEXT, val_str TEXT, val_num REAL, uom TEXT,
    data_key INTEGER NOT NULL, inst_key INTEGER NOT NULL, inst_row_key INTEGER NOT NULL,
    popln_tmstp TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (product_key, type_key, eff_tmstp, ver_tmstp)
);

-------------------------------- ORDER ---------------------------------
CREATE TABLE order_idfr (
    order_idfr TEXT NOT NULL, eff_tmstp TEXT NOT NULL, ver_tmstp TEXT NOT NULL,
    row_st TEXT NOT NULL, order_key INTEGER NOT NULL,
    data_key INTEGER NOT NULL, inst_key INTEGER NOT NULL, inst_row_key INTEGER NOT NULL,
    popln_tmstp TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (order_idfr, eff_tmstp, ver_tmstp)
);
CREATE TABLE order_focal (
    order_key INTEGER NOT NULL, eff_tmstp TEXT NOT NULL, ver_tmstp TEXT NOT NULL,
    row_st TEXT NOT NULL, data_key INTEGER NOT NULL, inst_key INTEGER NOT NULL,
    inst_row_key INTEGER NOT NULL, popln_tmstp TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (order_key)
);
CREATE TABLE order_desc (
    order_key INTEGER NOT NULL, type_key INTEGER NOT NULL, eff_tmstp TEXT NOT NULL,
    ver_tmstp TEXT NOT NULL, seq_nbr INTEGER NOT NULL DEFAULT 0, row_st TEXT NOT NULL,
    sta_tmstp TEXT, end_tmstp TEXT, val_str TEXT, val_num REAL, uom TEXT,
    data_key INTEGER NOT NULL, inst_key INTEGER NOT NULL, inst_row_key INTEGER NOT NULL,
    popln_tmstp TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (order_key, type_key, eff_tmstp, ver_tmstp)
);

---------------------------- RELATIONSHIPS -----------------------------
-- Relationship table naming: [ENTITY1]_[ENTITY2]_X. One _X table can
-- hold several relationship kinds, separated by type_key.
CREATE TABLE order_customer_x (
    order_key    INTEGER NOT NULL,   -- driving entity
    customer_key INTEGER NOT NULL,   -- related entity
    type_key     INTEGER NOT NULL,   -- which relationship (PLACED_BY, ...)
    eff_tmstp    TEXT NOT NULL, ver_tmstp TEXT NOT NULL, row_st TEXT NOT NULL,
    data_key INTEGER NOT NULL, inst_key INTEGER NOT NULL, inst_row_key INTEGER NOT NULL,
    popln_tmstp TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (order_key, customer_key, type_key, eff_tmstp, ver_tmstp)
);
CREATE TABLE order_product_x (
    order_key    INTEGER NOT NULL,
    product_key  INTEGER NOT NULL,
    type_key     INTEGER NOT NULL,
    eff_tmstp    TEXT NOT NULL, ver_tmstp TEXT NOT NULL, row_st TEXT NOT NULL,
    data_key INTEGER NOT NULL, inst_key INTEGER NOT NULL, inst_row_key INTEGER NOT NULL,
    popln_tmstp TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (order_key, product_key, type_key, eff_tmstp, ver_tmstp)
);
