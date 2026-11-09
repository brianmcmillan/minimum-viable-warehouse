-- =====================================================================
-- HOOK :: RAW LAYER (separate durable database)
-- ---------------------------------------------------------------------
-- The shared archive discipline: every delivery captured verbatim,
-- pre-dedup, append-only with NO unlock path, self-describing, and
-- COMPLETE -- which is what lets `make rebuild` regenerate the frames.
-- (HOOK frames are delta-compressed: an unchanged FULL restatement writes
-- no frame row. The archive keeps the verbatim deliveries the frames
-- drop, shared byte-for-byte with every sibling demo.)
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

CREATE TABLE IF NOT EXISTS hist_customer (
    file_id TEXT NOT NULL REFERENCES loaded_files(file_id),
    load_seq INTEGER NOT NULL, batch_ts TEXT NOT NULL, seq_nbr INTEGER NOT NULL,
    customer_id TEXT NOT NULL, full_name TEXT, email_addr TEXT, signup_date TEXT,
    extract_dt TEXT NOT NULL, op TEXT NOT NULL, load_mode TEXT NOT NULL,
    archived_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (file_id, seq_nbr)
);
CREATE TABLE IF NOT EXISTS hist_product (
    file_id TEXT NOT NULL REFERENCES loaded_files(file_id),
    load_seq INTEGER NOT NULL, batch_ts TEXT NOT NULL, seq_nbr INTEGER NOT NULL,
    sku TEXT NOT NULL, prod_name TEXT, price REAL, currency TEXT,
    extract_dt TEXT NOT NULL, op TEXT NOT NULL, load_mode TEXT NOT NULL,
    archived_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (file_id, seq_nbr)
);
CREATE TABLE IF NOT EXISTS hist_order (
    file_id TEXT NOT NULL REFERENCES loaded_files(file_id),
    load_seq INTEGER NOT NULL, batch_ts TEXT NOT NULL, seq_nbr INTEGER NOT NULL,
    order_ref TEXT NOT NULL, customer_ref TEXT, status TEXT, amount REAL,
    currency TEXT, placed_at TEXT,
    extract_dt TEXT NOT NULL, op TEXT NOT NULL, load_mode TEXT NOT NULL,
    archived_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (file_id, seq_nbr)
);
CREATE TABLE IF NOT EXISTS hist_order_line (
    file_id TEXT NOT NULL REFERENCES loaded_files(file_id),
    load_seq INTEGER NOT NULL, batch_ts TEXT NOT NULL, seq_nbr INTEGER NOT NULL,
    order_ref TEXT NOT NULL, sku TEXT NOT NULL,
    extract_dt TEXT NOT NULL, op TEXT NOT NULL, load_mode TEXT NOT NULL,
    archived_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (file_id, seq_nbr)
);

CREATE TRIGGER IF NOT EXISTS trg_hc_nu BEFORE UPDATE ON hist_customer
BEGIN SELECT RAISE(ABORT,'archive is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_hc_nd BEFORE DELETE ON hist_customer
BEGIN SELECT RAISE(ABORT,'archive is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_hp_nu BEFORE UPDATE ON hist_product
BEGIN SELECT RAISE(ABORT,'archive is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_hp_nd BEFORE DELETE ON hist_product
BEGIN SELECT RAISE(ABORT,'archive is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_ho_nu BEFORE UPDATE ON hist_order
BEGIN SELECT RAISE(ABORT,'archive is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_ho_nd BEFORE DELETE ON hist_order
BEGIN SELECT RAISE(ABORT,'archive is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_hl_nu BEFORE UPDATE ON hist_order_line
BEGIN SELECT RAISE(ABORT,'archive is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_hl_nd BEFORE DELETE ON hist_order_line
BEGIN SELECT RAISE(ABORT,'archive is append-only'); END;
