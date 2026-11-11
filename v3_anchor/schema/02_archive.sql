-- =====================================================================
-- ANCHOR :: RAW LAYER (the archive database -- a separate file)
-- ---------------------------------------------------------------------
-- The Focal demo's archive, carried over unchanged in shape and in
-- guarantees: every delivery captured verbatim (pre-dedup) before it is
-- applied; append-only with NO unlock path; self-describing (load_seq
-- and batch_ts denormalised onto every row); and COMPLETE, which is
-- what lets ordered replay reproduce every anchor surrogate key.
-- Applied with IF NOT EXISTS by init_db.sh, which never drops this file.
-- =====================================================================

CREATE TABLE IF NOT EXISTS loaded_files (
    file_id   TEXT PRIMARY KEY,
    load_seq  INTEGER NOT NULL UNIQUE,
    batch_ts  TEXT    NOT NULL,
    status    TEXT    NOT NULL DEFAULT 'STARTED',   -- STARTED | COMPLETE
    loaded_at TEXT    NOT NULL DEFAULT (datetime('now')),
    row_count INTEGER
);

CREATE TABLE IF NOT EXISTS source_landing_history (
    file_id        TEXT    NOT NULL REFERENCES loaded_files(file_id),
    load_seq       INTEGER NOT NULL,
    batch_ts       TEXT    NOT NULL,
    seq_nbr        INTEGER NOT NULL,   -- staged rowid; replay order within the file
    source_system  TEXT    NOT NULL,
    source_entity  TEXT    NOT NULL,
    business_key   TEXT    NOT NULL,
    attribute_name TEXT    NOT NULL,
    value_str      TEXT,
    value_num      REAL,
    value_ts       TEXT,
    extract_ts     TEXT    NOT NULL,
    op             TEXT    NOT NULL,
    load_mode      TEXT,
    archived_at    TEXT    NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (file_id, seq_nbr)
);

CREATE TRIGGER IF NOT EXISTS trg_slh_no_update
BEFORE UPDATE ON source_landing_history
BEGIN SELECT RAISE(ABORT,'source_landing_history is append-only'); END;

CREATE TRIGGER IF NOT EXISTS trg_slh_no_delete
BEFORE DELETE ON source_landing_history
BEGIN SELECT RAISE(ABORT,'source_landing_history is append-only'); END;
