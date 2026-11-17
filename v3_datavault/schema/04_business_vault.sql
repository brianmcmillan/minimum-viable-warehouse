-- =====================================================================
-- DV2.0 :: BUSINESS VAULT
--   effectivity satellite (insert-only), computed status satellite (a
--   view), and the query-assistance tables: current point-in-time
--   tables and an order bridge (generated, rewritten on each refresh)
-- ---------------------------------------------------------------------
-- The ORDER->CUSTOMER link has a DRIVING KEY: an order is placed by
-- exactly one customer at a time. When a delivery re-points an order,
-- the link table just gains a second pair -- it is the effectivity
-- satellite that says which pair is CURRENT for the driving key.
--
-- This follows the DV101 Baseline's insert-only effectivity pattern
-- (the one "with NO end-date ... 100% insert driven using LEAD/LAG"):
-- each row opens a pairing for the driving key; end dates are computed
-- on the way OUT via LEAD, never written. old_customer_bk points at the
-- pairing this row superseded, purely as an audit convenience.
--
-- This is the capability the Focal demo currently lacks: its load_rel.sh
-- leaves a re-pointed order attached to BOTH customers (its known
-- driving-key gap). See tests/fixtures/d6_repoint.sql.
--
-- ORDER->PRODUCT has no driving key (an order simply contains products),
-- so it gets no effectivity satellite.
-- =====================================================================

CREATE TABLE bv_order_customer_l_effsat (
    order_bk        TEXT NOT NULL,   -- the driving key
    customer_bk     TEXT NOT NULL,   -- pairing opened by this row
    ldts            TEXT NOT NULL,
    rsrc            TEXT NOT NULL,
    start_date      TEXT NOT NULL,
    old_customer_bk TEXT,            -- pairing this row superseded (audit)
    PRIMARY KEY (order_bk, customer_bk, ldts),
    FOREIGN KEY (order_bk, customer_bk)
        REFERENCES rv_order_customer_l (order_bk, customer_bk)
);

-- Pair history with computed end dates: LEAD over start_date within the
-- driving key. The newest row per driving key is the current pairing.
CREATE VIEW v_order_customer_eff_history AS
SELECT order_bk, customer_bk, start_date,
       COALESCE(LEAD(start_date) OVER (PARTITION BY order_bk ORDER BY start_date, ldts),
                '9999-12-31 23:59:59')                                   AS end_date,
       CASE WHEN LEAD(start_date) OVER (PARTITION BY order_bk ORDER BY start_date, ldts)
            IS NULL THEN 1 ELSE 0 END                                    AS iscurrent
FROM bv_order_customer_l_effsat;

CREATE VIEW v_order_customer_current AS
SELECT order_bk, customer_bk
FROM v_order_customer_eff_history WHERE iscurrent = 1;

CREATE TRIGGER bv_order_customer_l_effsat_no_update BEFORE UPDATE ON bv_order_customer_l_effsat
BEGIN SELECT RAISE(ABORT, 'bv_order_customer_l_effsat is insert-only'); END;
CREATE TRIGGER bv_order_customer_l_effsat_no_delete BEFORE DELETE ON bv_order_customer_l_effsat
BEGIN SELECT RAISE(ABORT, 'bv_order_customer_l_effsat is insert-only'); END;

-- =====================================================================
-- COMPUTED SATELLITE: the order-status decode
-- ---------------------------------------------------------------------
-- Each rv_order_hsat row with its decoded label, from the LATEST
-- ref_order_status row per code. It is a VIEW on purpose and must stay
-- one: a new reference row then relabels every historical row at once,
-- with no reload and no recompute. Materialise it and a rule change
-- would need a refresh. An unknown code decodes to itself, as the
-- mart's old CASE did; the ghost row decodes to NULL.
-- =====================================================================

CREATE VIEW bv_order_status_bsat AS
SELECT h.order_bk, h.ldts, h.rsrc,
       h.status                     AS status,        -- raw source code
       COALESCE(r.label, h.status)  AS status_label   -- the rule in force
FROM rv_order_hsat h
LEFT JOIN (SELECT code, label FROM (
             SELECT code, label,
                    ROW_NUMBER() OVER (PARTITION BY code ORDER BY ldts DESC) rn
             FROM ref_order_status)
           WHERE rn = 1) r
       ON r.code = h.status;

-- =====================================================================
-- QUERY ASSISTANCE
-- ---------------------------------------------------------------------
-- GENERATED TABLES. scripts/refresh_query_assist.sh deletes and
-- rewrites all four at the end of every delivery, in the apply path that
-- ingest and `make rebuild` share. They are the ONLY tables in the vault
-- that are rewritten; every rv_* table and the effectivity satellite are
-- insert-only and refuse UPDATE and DELETE. No source delivers these
-- rows and no business rule is applied in them: they only record where
-- the current rows are, so the info mart can reach them with equi-joins.
--
-- CURRENT POINT-IN-TIME (CPIT): one row per real hub key (never '0',
-- '-1' or '-2'). Each satellite on the hub gets a pointer pair
-- (<sat>_bk, <sat>_ldts) naming its current row: the key itself and the
-- newest ldts, or the ghost row ('0', '1900-01-01 00:00:00') when the
-- key has no row in that satellite. A pointer is never NULL, so the
-- mart joins through it with inner joins and a key without attributes
-- lands on the ghost row's NULLs. A deleted key keeps its row: its sts
-- pointer names the 'D' row.
--
-- For orders, eff_customer_bk / eff_ldts name the current effectivity
-- row (the order's current customer and when that pairing opened), or
-- ('0', '1900-01-01 00:00:00') when the order has no pairing. The
-- effectivity satellite carries no ghost row, so this pointer names the
-- customer rather than resolving through a join.
--
-- ORDER BRIDGE: one row per rv_order_product_l row -- the order, the
-- product, and the order's current customer from the effectivity
-- satellite ('0' when it has none). The info mart does not read it.
-- =====================================================================

CREATE TABLE bv_customer_cpit (
    customer_bk TEXT NOT NULL PRIMARY KEY,
    hsat_bk     TEXT NOT NULL,  hsat_ldts TEXT NOT NULL,   -- rv_customer_hsat
    sts_bk      TEXT NOT NULL,  sts_ldts  TEXT NOT NULL,   -- rv_customer_sts
    FOREIGN KEY (customer_bk)       REFERENCES rv_customer_h (customer_bk),
    FOREIGN KEY (hsat_bk, hsat_ldts) REFERENCES rv_customer_hsat (customer_bk, ldts),
    FOREIGN KEY (sts_bk, sts_ldts)   REFERENCES rv_customer_sts (customer_bk, ldts)
);

CREATE TABLE bv_product_cpit (
    product_bk TEXT NOT NULL PRIMARY KEY,
    hsat_bk    TEXT NOT NULL,  hsat_ldts TEXT NOT NULL,    -- rv_product_hsat
    sts_bk     TEXT NOT NULL,  sts_ldts  TEXT NOT NULL,    -- rv_product_sts
    FOREIGN KEY (product_bk)        REFERENCES rv_product_h (product_bk),
    FOREIGN KEY (hsat_bk, hsat_ldts) REFERENCES rv_product_hsat (product_bk, ldts),
    FOREIGN KEY (sts_bk, sts_ldts)   REFERENCES rv_product_sts (product_bk, ldts)
);

CREATE TABLE bv_order_cpit (
    order_bk        TEXT NOT NULL PRIMARY KEY,
    hsat_bk         TEXT NOT NULL,  hsat_ldts TEXT NOT NULL,  -- rv_order_hsat
    sts_bk          TEXT NOT NULL,  sts_ldts  TEXT NOT NULL,  -- rv_order_sts
    eff_customer_bk TEXT NOT NULL,  eff_ldts  TEXT NOT NULL,  -- bv_order_customer_l_effsat
    FOREIGN KEY (order_bk)          REFERENCES rv_order_h (order_bk),
    FOREIGN KEY (hsat_bk, hsat_ldts) REFERENCES rv_order_hsat (order_bk, ldts),
    FOREIGN KEY (sts_bk, sts_ldts)   REFERENCES rv_order_sts (order_bk, ldts)
);

CREATE TABLE bv_order_bridge (
    order_bk    TEXT NOT NULL,
    product_bk  TEXT NOT NULL,
    customer_bk TEXT NOT NULL,   -- current customer, '0' when none
    PRIMARY KEY (order_bk, product_bk),
    FOREIGN KEY (order_bk, product_bk) REFERENCES rv_order_product_l (order_bk, product_bk),
    FOREIGN KEY (customer_bk)          REFERENCES rv_customer_h (customer_bk)
);
