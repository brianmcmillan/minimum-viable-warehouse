-- =====================================================================
-- DV2.0 :: RAW VAULT  (hubs, satellites, status sats, links)
-- ---------------------------------------------------------------------
-- Insert-only, hard rules only. Naming follows the DV101 Baseline
-- conventions: rv_<entity>_h / _hsat / _l, with rsrc + ldts on every row.
--
-- NATURAL KEYS: hubs are keyed on the business key itself (hash keys are
-- optional in the standard and omitted here -- see DATAVAULT.md). Links
-- use composite natural-key PKs for the same reason.
--
-- RAW means RAW: OMS delivers status 'P'/'S'/'D'/'C' and that is exactly
-- what rv_order_hsat stores. The P->PENDING translation is a soft
-- business rule and lives downstream in the info mart -- where the Focal
-- demo applies it at ingest via meta_value_map, the vault keeps the
-- source value forever and derives on the way out.
--
-- Deletes NEVER remove rows. A status-tracking satellite (rv_*_sts)
-- records presence assertions: 'I' when a key is (re)inserted at source,
-- 'D' when a tombstone arrives or a FULL delivery omits the key. The
-- same absence-means-delete-only-under-FULL rule as the Focal demo,
-- expressed as satellite rows instead of row_st flags.
-- =====================================================================

--------------------------------- HUBS ---------------------------------
-- One row per business key, ever. First-seen wins; never updated.

CREATE TABLE rv_customer_h (
    customer_bk TEXT NOT NULL,
    ldts        TEXT NOT NULL,
    rsrc        TEXT NOT NULL,
    PRIMARY KEY (customer_bk)
);

CREATE TABLE rv_product_h (
    product_bk TEXT NOT NULL,
    ldts       TEXT NOT NULL,
    rsrc       TEXT NOT NULL,
    PRIMARY KEY (product_bk)
);

CREATE TABLE rv_order_h (
    order_bk TEXT NOT NULL,
    ldts     TEXT NOT NULL,
    rsrc     TEXT NOT NULL,
    PRIMARY KEY (order_bk)
);

------------------------------ SATELLITES ------------------------------
-- Descriptive attributes at WHOLE-ROW grain: any changed attribute
-- writes a complete new row (contrast: Focal versions each atomic
-- context independently). diff_str is the stored change-detection
-- string -- the would-be hashdiff, in plaintext.

CREATE TABLE rv_customer_hsat (
    customer_bk TEXT NOT NULL,
    ldts        TEXT NOT NULL,
    rsrc        TEXT NOT NULL,
    diff_str    TEXT NOT NULL,
    full_name   TEXT,
    email_addr  TEXT,
    signup_date TEXT,
    PRIMARY KEY (customer_bk, ldts),
    FOREIGN KEY (customer_bk) REFERENCES rv_customer_h (customer_bk)
);

CREATE TABLE rv_product_hsat (
    product_bk TEXT NOT NULL,
    ldts       TEXT NOT NULL,
    rsrc       TEXT NOT NULL,
    diff_str   TEXT NOT NULL,
    prod_name  TEXT,
    price      REAL,
    currency   TEXT,
    PRIMARY KEY (product_bk, ldts),
    FOREIGN KEY (product_bk) REFERENCES rv_product_h (product_bk)
);

CREATE TABLE rv_order_hsat (
    order_bk  TEXT NOT NULL,
    ldts      TEXT NOT NULL,
    rsrc      TEXT NOT NULL,
    diff_str  TEXT NOT NULL,
    status    TEXT,            -- RAW source code: P/S/D/C
    amount    REAL,
    currency  TEXT,
    placed_at TEXT,
    PRIMARY KEY (order_bk, ldts),
    FOREIGN KEY (order_bk) REFERENCES rv_order_h (order_bk)
);

-------------------------- STATUS-TRACKING SATS -------------------------
-- Presence assertions, change-only: a row is written only when the
-- status flips. sts = 'I' (present at source) | 'D' (deleted at source).

CREATE TABLE rv_customer_sts (
    customer_bk TEXT NOT NULL,
    ldts        TEXT NOT NULL,
    rsrc        TEXT NOT NULL,
    sts         TEXT NOT NULL CHECK (sts IN ('I','D')),
    PRIMARY KEY (customer_bk, ldts),
    FOREIGN KEY (customer_bk) REFERENCES rv_customer_h (customer_bk)
);

CREATE TABLE rv_product_sts (
    product_bk TEXT NOT NULL,
    ldts       TEXT NOT NULL,
    rsrc       TEXT NOT NULL,
    sts        TEXT NOT NULL CHECK (sts IN ('I','D')),
    PRIMARY KEY (product_bk, ldts),
    FOREIGN KEY (product_bk) REFERENCES rv_product_h (product_bk)
);

CREATE TABLE rv_order_sts (
    order_bk TEXT NOT NULL,
    ldts     TEXT NOT NULL,
    rsrc     TEXT NOT NULL,
    sts      TEXT NOT NULL CHECK (sts IN ('I','D')),
    PRIMARY KEY (order_bk, ldts),
    FOREIGN KEY (order_bk) REFERENCES rv_order_h (order_bk)
);

-------------------------------- LINKS ---------------------------------
-- One row per distinct relationship pair, ever. Insert-only; history
-- and currency of a pair live in the effectivity satellite, not here.

CREATE TABLE rv_order_customer_l (
    order_bk    TEXT NOT NULL,
    customer_bk TEXT NOT NULL,
    ldts        TEXT NOT NULL,
    rsrc        TEXT NOT NULL,
    PRIMARY KEY (order_bk, customer_bk),
    FOREIGN KEY (order_bk)    REFERENCES rv_order_h (order_bk),
    FOREIGN KEY (customer_bk) REFERENCES rv_customer_h (customer_bk)
);

CREATE TABLE rv_order_product_l (
    order_bk   TEXT NOT NULL,
    product_bk TEXT NOT NULL,
    ldts       TEXT NOT NULL,
    rsrc       TEXT NOT NULL,
    PRIMARY KEY (order_bk, product_bk),
    FOREIGN KEY (order_bk)   REFERENCES rv_order_h (order_bk),
    FOREIGN KEY (product_bk) REFERENCES rv_product_h (product_bk)
);
