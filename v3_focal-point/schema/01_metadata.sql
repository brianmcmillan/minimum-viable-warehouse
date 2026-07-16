-- =====================================================================
-- FOCAL :: METADATA (INCREMENTAL-AWARE / narrow-source variant)
-- ---------------------------------------------------------------------
-- Extends the canonical variant with the machinery a real feed cadence
-- needs: an explicit ingestion strategy, per-delivery load mode,
-- tombstone deletes, recency de-duplication, and file-level load control.
--
-- The central safety rule:  ABSENCE == DELETE only for a FULL delivery.
-- An INCREMENTAL (windowed) delivery NEVER infers deletes from absence;
-- deletes must arrive as explicit tombstones (op='DELETE') or be found
-- by a later FULL reconciliation.
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
    op             TEXT NOT NULL DEFAULT 'UPSERT',  -- UPSERT | DELETE (tombstone)
    load_mode      TEXT                              -- FULL | INCREMENTAL (per delivery)
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

-- Declared default ingestion strategy per feed (a delivery's load_mode
-- overrides it -- a normally-INCREMENTAL source can send a FULL batch).
CREATE TABLE meta_source_feed (
    source_system      TEXT NOT NULL,
    source_entity      TEXT NOT NULL,
    ingestion_strategy TEXT NOT NULL,   -- FULL | INCREMENTAL
    PRIMARY KEY (source_system, source_entity)
);

-- Load control (loaded_files) used to live here. It now lives in the
-- ARCHIVE database (schema/05_archive.sql), alongside the raw deliveries
-- it controls: this database is disposable and rebuild.sh recreates it
-- from scratch, so anything that must survive a rebuild cannot live here.

-- ---- unchanged metadata (same as canonical) ----
CREATE TABLE meta_entity (
    entity_id TEXT PRIMARY KEY, definition TEXT NOT NULL, key_col TEXT NOT NULL);
CREATE TABLE meta_atomic_context (
    type_key INTEGER PRIMARY KEY, entity_id TEXT NOT NULL REFERENCES meta_entity(entity_id),
    context_name TEXT NOT NULL, definition TEXT NOT NULL);
CREATE TABLE meta_attribute (
    type_key INTEGER NOT NULL REFERENCES meta_atomic_context(type_key),
    attr_name TEXT NOT NULL, phys_column TEXT NOT NULL, data_type TEXT NOT NULL,
    PRIMARY KEY (type_key, attr_name));
CREATE TABLE meta_relationship (
    type_key INTEGER PRIMARY KEY, rel_name TEXT NOT NULL,
    source_entity TEXT NOT NULL REFERENCES meta_entity(entity_id),
    target_entity TEXT NOT NULL REFERENCES meta_entity(entity_id), x_table TEXT NOT NULL);
CREATE TABLE meta_source_map (
    map_id INTEGER PRIMARY KEY, entity_id TEXT NOT NULL, type_key INTEGER,
    source_system TEXT NOT NULL, source_entity TEXT NOT NULL, role TEXT NOT NULL,
    source_attribute TEXT, phys_column TEXT, default_value TEXT);
CREATE TABLE meta_value_map (
    type_key INTEGER NOT NULL, source_value TEXT NOT NULL, target_value TEXT NOT NULL,
    PRIMARY KEY (type_key, source_value));
CREATE TABLE meta_procinst (
    inst_key INTEGER PRIMARY KEY AUTOINCREMENT, pipeline TEXT NOT NULL,
    batch_ts TEXT NOT NULL, sql_text TEXT NOT NULL,
    run_tmstp TEXT NOT NULL DEFAULT (datetime('now')));
CREATE TABLE meta_rel_map (
    type_key INTEGER PRIMARY KEY REFERENCES meta_relationship(type_key),
    source_system TEXT NOT NULL, source_entity TEXT NOT NULL,
    source_key_attr TEXT NOT NULL, target_key_attr TEXT NOT NULL);
