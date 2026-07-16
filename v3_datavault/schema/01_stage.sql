-- =====================================================================
-- DV2.0 :: STAGE LEVEL 1  (one wide table per source feed)
-- ---------------------------------------------------------------------
-- The Data Vault counterpart of the Focal demo's source_landing_stage.
-- Where Focal lands ONE generic narrow (EAV) table for every feed, DV
-- stages each feed in its own wide table shaped like the source extract.
-- A delivery file INSERTs here; the driver clears these tables first.
--
-- op / load_mode carry the same delivery semantics as the Focal demo:
--   op        = UPSERT | DELETE (tombstone)
--   load_mode = FULL | INCREMENTAL   -- the central safety rule is shared:
--               ABSENCE means DELETE only for a FULL delivery.
--
-- Layer naming follows the DV101 Baseline convention (_l1 / _l2).
-- SQLite has no schemas, so prefixes stand in for baseline_stage etc.
-- =====================================================================

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

-- One-row parameter table read by the stage-2 views: the logical load
-- timestamp (ldts) of the delivery being processed. The driver sets it.
-- (The training package uses current_timestamp in the views; a parameter
-- keeps every run deterministic, exactly like the Focal demo's BATCH_TS.)
CREATE TABLE dv_load_params (
    batch_ts TEXT NOT NULL
);

-- Load control, mirroring the Focal demo's loaded_files: a delivery id
-- already COMPLETE is skipped; STARTED-but-never-COMPLETE is retryable.
CREATE TABLE dv_load_audit (
    file_id   TEXT PRIMARY KEY,
    load_seq  INTEGER NOT NULL UNIQUE,
    batch_ts  TEXT NOT NULL,
    status    TEXT NOT NULL DEFAULT 'STARTED',   -- STARTED | COMPLETE
    loaded_at TEXT NOT NULL DEFAULT (datetime('now')),
    row_count INTEGER
);
