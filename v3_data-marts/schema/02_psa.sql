-- =====================================================================
-- KIMBALL :: PERSISTENT STAGING AREA  (a separate, durable database)
-- ---------------------------------------------------------------------
-- The Focal demo's raw-layer archive, applied to Kimball's world: every
-- delivery is captured verbatim, append-only, BEFORE it is applied, and
-- `make rebuild` regenerates the entire mart by replaying it. Kimball
-- calls this a persistent staging area; the properties that make it a
-- real one are borrowed wholesale from the Focal archive:
--
--   1. APPEND-ONLY, absolutely -- the triggers below have no unlock
--      path, because nothing in this project deletes a staged fact.
--   2. SELF-DESCRIBING -- load_seq and batch_ts are denormalised onto
--      every row; the PSA replays even if the mart file is destroyed.
--   3. COMPLETE -- replaying every delivery in load_seq order re-runs
--      SCD2 version assignment against identical prior state, so even
--      the dimension SURROGATE KEYS come back identical. Prune one
--      delivery and that stops being true.
--
-- One wide history table per feed (Kimball PSAs mirror source shapes),
-- plus the load-control manifest, which lives here because it must
-- outlive the disposable mart.
-- Applied with IF NOT EXISTS by init_db.sh, which never drops this file.
-- =====================================================================

CREATE TABLE IF NOT EXISTS loaded_files (
    file_id   TEXT PRIMARY KEY,        -- delivery identity (batch/version, not filename)
    load_seq  INTEGER NOT NULL UNIQUE, -- replay order; assigned once, on first sight
    batch_ts  TEXT    NOT NULL,        -- logical load ts; reproduces SCD2 row_eff_ts
    status    TEXT    NOT NULL DEFAULT 'STARTED',  -- STARTED | COMPLETE
    loaded_at TEXT    NOT NULL DEFAULT (datetime('now')),
    row_count INTEGER                  -- staged rows; guards a reused file_id
);

-- seq_nbr is the staged rowid: replay restores stage in this order
-- because the recency-dedup tiebreak reads it (same load-bearing role
-- as in the Focal archive).

CREATE TABLE IF NOT EXISTS psa_customer (
    file_id TEXT NOT NULL REFERENCES loaded_files(file_id),
    load_seq INTEGER NOT NULL, batch_ts TEXT NOT NULL, seq_nbr INTEGER NOT NULL,
    customer_id TEXT NOT NULL, full_name TEXT, email_addr TEXT, signup_date TEXT,
    extract_dt TEXT NOT NULL, op TEXT NOT NULL, load_mode TEXT NOT NULL,
    archived_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (file_id, seq_nbr)
);

CREATE TABLE IF NOT EXISTS psa_product (
    file_id TEXT NOT NULL REFERENCES loaded_files(file_id),
    load_seq INTEGER NOT NULL, batch_ts TEXT NOT NULL, seq_nbr INTEGER NOT NULL,
    sku TEXT NOT NULL, prod_name TEXT, price REAL, currency TEXT,
    extract_dt TEXT NOT NULL, op TEXT NOT NULL, load_mode TEXT NOT NULL,
    archived_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (file_id, seq_nbr)
);

CREATE TABLE IF NOT EXISTS psa_order (
    file_id TEXT NOT NULL REFERENCES loaded_files(file_id),
    load_seq INTEGER NOT NULL, batch_ts TEXT NOT NULL, seq_nbr INTEGER NOT NULL,
    order_ref TEXT NOT NULL, customer_ref TEXT, status TEXT, amount REAL,
    currency TEXT, placed_at TEXT,
    extract_dt TEXT NOT NULL, op TEXT NOT NULL, load_mode TEXT NOT NULL,
    archived_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (file_id, seq_nbr)
);

CREATE TABLE IF NOT EXISTS psa_order_line (
    file_id TEXT NOT NULL REFERENCES loaded_files(file_id),
    load_seq INTEGER NOT NULL, batch_ts TEXT NOT NULL, seq_nbr INTEGER NOT NULL,
    order_ref TEXT NOT NULL, sku TEXT NOT NULL,
    extract_dt TEXT NOT NULL, op TEXT NOT NULL, load_mode TEXT NOT NULL,
    archived_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (file_id, seq_nbr)
);

CREATE INDEX IF NOT EXISTS ix_psa_cust_replay  ON psa_customer(load_seq);
CREATE INDEX IF NOT EXISTS ix_psa_prod_replay  ON psa_product(load_seq);
CREATE INDEX IF NOT EXISTS ix_psa_ord_replay   ON psa_order(load_seq);
CREATE INDEX IF NOT EXISTS ix_psa_line_replay  ON psa_order_line(load_seq);

-- Append-only, enforced. INSERT OR IGNORE does not fire these (unlike
-- OR REPLACE), which is what makes re-archiving a retried delivery a
-- safe no-op.
CREATE TRIGGER IF NOT EXISTS trg_psa_cust_nu BEFORE UPDATE ON psa_customer
BEGIN SELECT RAISE(ABORT,'psa is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_psa_cust_nd BEFORE DELETE ON psa_customer
BEGIN SELECT RAISE(ABORT,'psa is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_psa_prod_nu BEFORE UPDATE ON psa_product
BEGIN SELECT RAISE(ABORT,'psa is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_psa_prod_nd BEFORE DELETE ON psa_product
BEGIN SELECT RAISE(ABORT,'psa is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_psa_ord_nu BEFORE UPDATE ON psa_order
BEGIN SELECT RAISE(ABORT,'psa is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_psa_ord_nd BEFORE DELETE ON psa_order
BEGIN SELECT RAISE(ABORT,'psa is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_psa_line_nu BEFORE UPDATE ON psa_order_line
BEGIN SELECT RAISE(ABORT,'psa is append-only'); END;
CREATE TRIGGER IF NOT EXISTS trg_psa_line_nd BEFORE DELETE ON psa_order_line
BEGIN SELECT RAISE(ABORT,'psa is append-only'); END;
