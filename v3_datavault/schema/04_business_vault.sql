-- =====================================================================
-- DV2.0 :: BUSINESS VAULT  (effectivity satellite, insert-only)
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
