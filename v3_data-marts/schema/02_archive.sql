-- =====================================================================
-- KIMBALL :: ARCHIVE  (raw layer, a separate durable database)
-- ---------------------------------------------------------------------
-- The shared archive discipline, applied to Kimball's world -- what
-- Kimball practice calls a persistent staging area. Every delivery is
-- captured verbatim, pre-dedup, append-only, BEFORE it is applied, and
-- `make rebuild` regenerates the entire star by replaying it:
--
--   1. APPEND-ONLY, absolutely -- the triggers below have no unlock
--      path, because nothing in this project deletes a staged fact.
--   2. SELF-DESCRIBING -- load_seq and batch_ts are denormalised onto
--      every row; the archive replays even if the star file is destroyed.
--   3. COMPLETE -- replaying every delivery in load_seq order re-runs
--      SCD2 version assignment against identical prior state, so even
--      the dimension SURROGATE KEYS come back identical. Prune one
--      delivery and that stops being true.
--
-- One wide history table per feed, plus the load-control manifest,
-- which lives here because it must outlive the disposable star. The
-- DDL is identical to the sibling demos' archives, byte for byte.
--
-- loaded_files: file_id is the delivery identity (batch/version, not
-- filename); load_seq is the replay order, assigned once on first
-- sight; batch_ts is the logical load ts that reproduces SCD2
-- row_eff_ts; row_count guards a reused file_id.
--
-- hist_*.seq_nbr is the staged rowid: replay restores stage in this
-- order because the recency-dedup tiebreak reads it.
--
-- INSERT OR IGNORE does not fire the append-only triggers (unlike
-- OR REPLACE), which is what makes re-archiving a retried delivery a
-- safe no-op.
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
