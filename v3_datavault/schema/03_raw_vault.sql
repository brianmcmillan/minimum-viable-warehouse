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
-- what rv_order_hsat stores. The code list itself is reference data
-- (ref_order_status, below); applying it is a soft business rule and
-- lives downstream in the business vault's computed satellite
-- bv_order_status_bsat -- where the Focal demo applies it at ingest via
-- meta_value_map, the vault keeps the source value forever and derives
-- on the way out.
--
-- RESERVED KEYS: every hub holds three rows that no source delivered
-- ('0' ghost, '-1' required key left null, '-2' optional key left null)
-- and every satellite one ghost row for '0'. They are written here, at
-- init, and nowhere else; see the end of this file.
--
-- Insert-only is enforced, not just followed: every table in this file
-- carries UPDATE and DELETE triggers that abort, with no unlock path.
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
-- The ghost row for key '0' (see RESERVED KEYS) is the one row with no sts.

CREATE TABLE rv_customer_sts (
    customer_bk TEXT NOT NULL,
    ldts        TEXT NOT NULL,
    rsrc        TEXT NOT NULL,
    sts         TEXT CHECK (sts IN ('I','D')),
    CHECK ((sts IS NULL) = (customer_bk = '0')),  -- only the ghost row has no sts
    PRIMARY KEY (customer_bk, ldts),
    FOREIGN KEY (customer_bk) REFERENCES rv_customer_h (customer_bk)
);

CREATE TABLE rv_product_sts (
    product_bk TEXT NOT NULL,
    ldts       TEXT NOT NULL,
    rsrc       TEXT NOT NULL,
    sts        TEXT CHECK (sts IN ('I','D')),
    CHECK ((sts IS NULL) = (product_bk = '0')),  -- only the ghost row has no sts
    PRIMARY KEY (product_bk, ldts),
    FOREIGN KEY (product_bk) REFERENCES rv_product_h (product_bk)
);

CREATE TABLE rv_order_sts (
    order_bk TEXT NOT NULL,
    ldts     TEXT NOT NULL,
    rsrc     TEXT NOT NULL,
    sts      TEXT CHECK (sts IN ('I','D')),
    CHECK ((sts IS NULL) = (order_bk = '0')),  -- only the ghost row has no sts
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

------------------------------- REFERENCE ------------------------------
-- The order-status code list. Insert-only: a code is relabelled by
-- inserting a newer row, and the latest row per code (by ldts) is the
-- rule in force. Earlier rows stay, so the rule's own history is kept.
-- The seed rows are the decode the info mart used to hard-code.

CREATE TABLE ref_order_status (
    code  TEXT NOT NULL,
    label TEXT NOT NULL,
    ldts  TEXT NOT NULL,
    rsrc  TEXT NOT NULL,
    PRIMARY KEY (code, ldts)
);

INSERT INTO ref_order_status(code, label, ldts, rsrc) VALUES
  ('P', 'PENDING',   '1900-01-01 00:00:00', 'BASELINE-refdata'),
  ('S', 'SHIPPED',   '1900-01-01 00:00:00', 'BASELINE-refdata'),
  ('D', 'DELIVERED', '1900-01-01 00:00:00', 'BASELINE-refdata'),
  ('C', 'CANCELLED', '1900-01-01 00:00:00', 'BASELINE-refdata');

----------------------------- RESERVED KEYS ----------------------------
-- Written once, at init, so `make rebuild` re-creates them with the
-- schema. In the standard these are the hashes of the reserved values;
-- with natural keys this demo stores '0', '-1' and '-2' as they are.
--   '0'   BASELINE-ghostrec          the ghost record: a point-in-time
--                                    pointer with nothing to point at
--                                    lands here, never on NULL
--   '-1'  BASELINE-nullkey-required  a required link end the source left null
--   '-2'  BASELINE-nullkey-optional  an optional link end the source left null
-- One ghost row per satellite: key '0', the same ldts, NULL descriptive
-- columns. diff_str is '' (the standard's ghost hashdiff is a fixed
-- zero value; the stored string has no hash to zero).

INSERT INTO rv_customer_h(customer_bk, ldts, rsrc) VALUES
  ('0',  '1900-01-01 00:00:00', 'BASELINE-ghostrec'),
  ('-1', '1900-01-01 00:00:00', 'BASELINE-nullkey-required'),
  ('-2', '1900-01-01 00:00:00', 'BASELINE-nullkey-optional');
INSERT INTO rv_product_h(product_bk, ldts, rsrc) VALUES
  ('0',  '1900-01-01 00:00:00', 'BASELINE-ghostrec'),
  ('-1', '1900-01-01 00:00:00', 'BASELINE-nullkey-required'),
  ('-2', '1900-01-01 00:00:00', 'BASELINE-nullkey-optional');
INSERT INTO rv_order_h(order_bk, ldts, rsrc) VALUES
  ('0',  '1900-01-01 00:00:00', 'BASELINE-ghostrec'),
  ('-1', '1900-01-01 00:00:00', 'BASELINE-nullkey-required'),
  ('-2', '1900-01-01 00:00:00', 'BASELINE-nullkey-optional');

INSERT INTO rv_customer_hsat(customer_bk, ldts, rsrc, diff_str) VALUES ('0', '1900-01-01 00:00:00', 'BASELINE-ghostrec', '');
INSERT INTO rv_product_hsat(product_bk, ldts, rsrc, diff_str) VALUES ('0', '1900-01-01 00:00:00', 'BASELINE-ghostrec', '');
INSERT INTO rv_order_hsat(order_bk, ldts, rsrc, diff_str) VALUES ('0', '1900-01-01 00:00:00', 'BASELINE-ghostrec', '');
INSERT INTO rv_customer_sts(customer_bk, ldts, rsrc, sts) VALUES ('0', '1900-01-01 00:00:00', 'BASELINE-ghostrec', NULL);
INSERT INTO rv_product_sts(product_bk, ldts, rsrc, sts) VALUES ('0', '1900-01-01 00:00:00', 'BASELINE-ghostrec', NULL);
INSERT INTO rv_order_sts(order_bk, ldts, rsrc, sts) VALUES ('0', '1900-01-01 00:00:00', 'BASELINE-ghostrec', NULL);

-- No loader may write a reserved row: a row for '0', '-1' or '-2' in a
-- hub or satellite must carry a BASELINE- record source. (Loaders never
-- try -- apply_delivery.sh rejects a delivery naming a reserved value,
-- and hub loads skip keys that already exist -- this is the backstop.)
CREATE TRIGGER rv_customer_h_reserved BEFORE INSERT ON rv_customer_h
WHEN NEW.customer_bk IN ('0','-1','-2') AND NEW.rsrc NOT LIKE 'BASELINE-%'
BEGIN SELECT RAISE(ABORT, 'rv_customer_h: reserved key ' || NEW.customer_bk || ' is written at init only'); END;
CREATE TRIGGER rv_customer_hsat_reserved BEFORE INSERT ON rv_customer_hsat
WHEN NEW.customer_bk IN ('0','-1','-2') AND NEW.rsrc NOT LIKE 'BASELINE-%'
BEGIN SELECT RAISE(ABORT, 'rv_customer_hsat: reserved key ' || NEW.customer_bk || ' is written at init only'); END;
CREATE TRIGGER rv_customer_sts_reserved BEFORE INSERT ON rv_customer_sts
WHEN NEW.customer_bk IN ('0','-1','-2') AND NEW.rsrc NOT LIKE 'BASELINE-%'
BEGIN SELECT RAISE(ABORT, 'rv_customer_sts: reserved key ' || NEW.customer_bk || ' is written at init only'); END;
CREATE TRIGGER rv_product_h_reserved BEFORE INSERT ON rv_product_h
WHEN NEW.product_bk IN ('0','-1','-2') AND NEW.rsrc NOT LIKE 'BASELINE-%'
BEGIN SELECT RAISE(ABORT, 'rv_product_h: reserved key ' || NEW.product_bk || ' is written at init only'); END;
CREATE TRIGGER rv_product_hsat_reserved BEFORE INSERT ON rv_product_hsat
WHEN NEW.product_bk IN ('0','-1','-2') AND NEW.rsrc NOT LIKE 'BASELINE-%'
BEGIN SELECT RAISE(ABORT, 'rv_product_hsat: reserved key ' || NEW.product_bk || ' is written at init only'); END;
CREATE TRIGGER rv_product_sts_reserved BEFORE INSERT ON rv_product_sts
WHEN NEW.product_bk IN ('0','-1','-2') AND NEW.rsrc NOT LIKE 'BASELINE-%'
BEGIN SELECT RAISE(ABORT, 'rv_product_sts: reserved key ' || NEW.product_bk || ' is written at init only'); END;
CREATE TRIGGER rv_order_h_reserved BEFORE INSERT ON rv_order_h
WHEN NEW.order_bk IN ('0','-1','-2') AND NEW.rsrc NOT LIKE 'BASELINE-%'
BEGIN SELECT RAISE(ABORT, 'rv_order_h: reserved key ' || NEW.order_bk || ' is written at init only'); END;
CREATE TRIGGER rv_order_hsat_reserved BEFORE INSERT ON rv_order_hsat
WHEN NEW.order_bk IN ('0','-1','-2') AND NEW.rsrc NOT LIKE 'BASELINE-%'
BEGIN SELECT RAISE(ABORT, 'rv_order_hsat: reserved key ' || NEW.order_bk || ' is written at init only'); END;
CREATE TRIGGER rv_order_sts_reserved BEFORE INSERT ON rv_order_sts
WHEN NEW.order_bk IN ('0','-1','-2') AND NEW.rsrc NOT LIKE 'BASELINE-%'
BEGIN SELECT RAISE(ABORT, 'rv_order_sts: reserved key ' || NEW.order_bk || ' is written at init only'); END;

------------------------------ INSERT-ONLY -----------------------------
-- Every raw-vault table refuses UPDATE and DELETE. Rebuilding means a
-- fresh database (init_db.sh), never an edit in place.
CREATE TRIGGER rv_customer_h_no_update BEFORE UPDATE ON rv_customer_h
BEGIN SELECT RAISE(ABORT, 'rv_customer_h is insert-only'); END;
CREATE TRIGGER rv_customer_h_no_delete BEFORE DELETE ON rv_customer_h
BEGIN SELECT RAISE(ABORT, 'rv_customer_h is insert-only'); END;
CREATE TRIGGER rv_customer_hsat_no_update BEFORE UPDATE ON rv_customer_hsat
BEGIN SELECT RAISE(ABORT, 'rv_customer_hsat is insert-only'); END;
CREATE TRIGGER rv_customer_hsat_no_delete BEFORE DELETE ON rv_customer_hsat
BEGIN SELECT RAISE(ABORT, 'rv_customer_hsat is insert-only'); END;
CREATE TRIGGER rv_customer_sts_no_update BEFORE UPDATE ON rv_customer_sts
BEGIN SELECT RAISE(ABORT, 'rv_customer_sts is insert-only'); END;
CREATE TRIGGER rv_customer_sts_no_delete BEFORE DELETE ON rv_customer_sts
BEGIN SELECT RAISE(ABORT, 'rv_customer_sts is insert-only'); END;
CREATE TRIGGER rv_product_h_no_update BEFORE UPDATE ON rv_product_h
BEGIN SELECT RAISE(ABORT, 'rv_product_h is insert-only'); END;
CREATE TRIGGER rv_product_h_no_delete BEFORE DELETE ON rv_product_h
BEGIN SELECT RAISE(ABORT, 'rv_product_h is insert-only'); END;
CREATE TRIGGER rv_product_hsat_no_update BEFORE UPDATE ON rv_product_hsat
BEGIN SELECT RAISE(ABORT, 'rv_product_hsat is insert-only'); END;
CREATE TRIGGER rv_product_hsat_no_delete BEFORE DELETE ON rv_product_hsat
BEGIN SELECT RAISE(ABORT, 'rv_product_hsat is insert-only'); END;
CREATE TRIGGER rv_product_sts_no_update BEFORE UPDATE ON rv_product_sts
BEGIN SELECT RAISE(ABORT, 'rv_product_sts is insert-only'); END;
CREATE TRIGGER rv_product_sts_no_delete BEFORE DELETE ON rv_product_sts
BEGIN SELECT RAISE(ABORT, 'rv_product_sts is insert-only'); END;
CREATE TRIGGER rv_order_h_no_update BEFORE UPDATE ON rv_order_h
BEGIN SELECT RAISE(ABORT, 'rv_order_h is insert-only'); END;
CREATE TRIGGER rv_order_h_no_delete BEFORE DELETE ON rv_order_h
BEGIN SELECT RAISE(ABORT, 'rv_order_h is insert-only'); END;
CREATE TRIGGER rv_order_hsat_no_update BEFORE UPDATE ON rv_order_hsat
BEGIN SELECT RAISE(ABORT, 'rv_order_hsat is insert-only'); END;
CREATE TRIGGER rv_order_hsat_no_delete BEFORE DELETE ON rv_order_hsat
BEGIN SELECT RAISE(ABORT, 'rv_order_hsat is insert-only'); END;
CREATE TRIGGER rv_order_sts_no_update BEFORE UPDATE ON rv_order_sts
BEGIN SELECT RAISE(ABORT, 'rv_order_sts is insert-only'); END;
CREATE TRIGGER rv_order_sts_no_delete BEFORE DELETE ON rv_order_sts
BEGIN SELECT RAISE(ABORT, 'rv_order_sts is insert-only'); END;
CREATE TRIGGER rv_order_customer_l_no_update BEFORE UPDATE ON rv_order_customer_l
BEGIN SELECT RAISE(ABORT, 'rv_order_customer_l is insert-only'); END;
CREATE TRIGGER rv_order_customer_l_no_delete BEFORE DELETE ON rv_order_customer_l
BEGIN SELECT RAISE(ABORT, 'rv_order_customer_l is insert-only'); END;
CREATE TRIGGER rv_order_product_l_no_update BEFORE UPDATE ON rv_order_product_l
BEGIN SELECT RAISE(ABORT, 'rv_order_product_l is insert-only'); END;
CREATE TRIGGER rv_order_product_l_no_delete BEFORE DELETE ON rv_order_product_l
BEGIN SELECT RAISE(ABORT, 'rv_order_product_l is insert-only'); END;
CREATE TRIGGER ref_order_status_no_update BEFORE UPDATE ON ref_order_status
BEGIN SELECT RAISE(ABORT, 'ref_order_status is insert-only'); END;
CREATE TRIGGER ref_order_status_no_delete BEFORE DELETE ON ref_order_status
BEGIN SELECT RAISE(ABORT, 'ref_order_status is insert-only'); END;
