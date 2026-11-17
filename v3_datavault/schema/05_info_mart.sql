-- =====================================================================
-- DV2.0 :: INFO MART  (business-facing views over the vault)
-- ---------------------------------------------------------------------
-- Column-for-column mirrors of the Focal demo's v_customer / v_product /
-- v_order, so `make demo` output is directly comparable across models.
--
-- NO RULES LIVE HERE. The vault stores OMS's raw status codes; the
-- P->PENDING decode is the business vault's computed satellite
-- (bv_order_status_bsat, a view over ref_order_status). Insert a newer
-- reference row and every row -- past and present -- reflects it
-- instantly, because the raw value was never overwritten. (The Focal
-- demo translates at ingest and needs its archive + `make rebuild` to
-- achieve the same.)
--
-- "Current" comes from the business vault's CPIT tables: one row per
-- real key, pointing at the current row of each satellite (or at the
-- ghost row). The dimension and fact views reach those rows with inner
-- joins only. A key whose current sts row is 'D' is deleted at source
-- and excluded, exactly as Focal's row_st='N' drops facts from its views.
--
-- RESERVED KEYS: every view here excludes '0', '-1' and '-2'.
-- =====================================================================

-- Newest satellite row per key (the standard "current sat" subquery).
-- Kept for ad-hoc reading; the dimension and fact views use the CPITs.
CREATE VIEW v_customer_hsat_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_bk ORDER BY ldts DESC) rn
  FROM rv_customer_hsat WHERE customer_bk NOT IN ('0','-1','-2')
) WHERE rn = 1;

CREATE VIEW v_product_hsat_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY product_bk ORDER BY ldts DESC) rn
  FROM rv_product_hsat WHERE product_bk NOT IN ('0','-1','-2')
) WHERE rn = 1;

CREATE VIEW v_order_hsat_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY order_bk ORDER BY ldts DESC) rn
  FROM rv_order_hsat WHERE order_bk NOT IN ('0','-1','-2')
) WHERE rn = 1;

-- Latest presence assertion per key (the loaders read these too).
CREATE VIEW v_customer_sts_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_bk ORDER BY ldts DESC) rn
  FROM rv_customer_sts WHERE customer_bk NOT IN ('0','-1','-2')
) WHERE rn = 1;

CREATE VIEW v_product_sts_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY product_bk ORDER BY ldts DESC) rn
  FROM rv_product_sts WHERE product_bk NOT IN ('0','-1','-2')
) WHERE rn = 1;

CREATE VIEW v_order_sts_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY order_bk ORDER BY ldts DESC) rn
  FROM rv_order_sts WHERE order_bk NOT IN ('0','-1','-2')
) WHERE rn = 1;

---------------------------- DIMENSION VIEWS ---------------------------

CREATE VIEW dim_customer AS
SELECT p.customer_bk               AS customer_ref,
       s.full_name                 AS customer_name,
       s.email_addr                AS email,
       s.signup_date               AS signup_date
FROM bv_customer_cpit p
JOIN rv_customer_sts  st ON st.customer_bk = p.sts_bk  AND st.ldts = p.sts_ldts AND st.sts = 'I'
JOIN rv_customer_hsat s  ON s.customer_bk  = p.hsat_bk AND s.ldts  = p.hsat_ldts
WHERE p.customer_bk NOT IN ('0','-1','-2');

CREATE VIEW dim_product AS
SELECT p.product_bk AS sku,
       s.prod_name  AS product_name,
       s.price      AS price,
       s.currency   AS currency
FROM bv_product_cpit p
JOIN rv_product_sts  st ON st.product_bk = p.sts_bk  AND st.ldts = p.sts_ldts AND st.sts = 'I'
JOIN rv_product_hsat s  ON s.product_bk  = p.hsat_bk AND s.ldts  = p.hsat_ldts
WHERE p.product_bk NOT IN ('0','-1','-2');

------------------------------ FACT VIEW -------------------------------
-- placed_by resolves through the CPIT's current effectivity pointer,
-- then through dim_customer -- so a deleted customer, the null-key
-- customer '-1' and the ghost '0' all yield NULL, matching the Focal
-- demo's v_order behaviour.

CREATE VIEW fact_order AS
SELECT p.order_bk       AS order_ref,
       b.status_label   AS status,        -- decoded in the business vault
       s.amount         AS amount,
       s.currency       AS currency,
       s.placed_at      AS placed_at,
       (SELECT d.customer_name FROM dim_customer d
         WHERE d.customer_ref = p.eff_customer_bk) AS placed_by
FROM bv_order_cpit p
JOIN rv_order_sts         st ON st.order_bk = p.sts_bk  AND st.ldts = p.sts_ldts AND st.sts = 'I'
JOIN rv_order_hsat        s  ON s.order_bk  = p.hsat_bk AND s.ldts  = p.hsat_ldts
JOIN bv_order_status_bsat b  ON b.order_bk  = p.hsat_bk AND b.ldts  = p.hsat_ldts
WHERE p.order_bk NOT IN ('0','-1','-2');

----------------------------- AUDIT VIEWS ------------------------------
-- Full timeline of order status: RAW next to decoded, to make the
-- hard-rule / soft-rule split visible.
CREATE VIEW v_order_status_history AS
SELECT order_bk AS order_ref, ldts, rsrc,
       status       AS raw_status,
       status_label AS status
FROM bv_order_status_bsat
WHERE order_bk NOT IN ('0','-1','-2')
ORDER BY order_bk, ldts;

-- Presence timeline per key across all three entities: when each key
-- was asserted present or deleted, and by which delivery.
CREATE VIEW v_status_history AS
SELECT 'CUSTOMER' AS entity, customer_bk AS business_key, ldts, rsrc, sts FROM rv_customer_sts
 WHERE customer_bk NOT IN ('0','-1','-2')
UNION ALL
SELECT 'PRODUCT',  product_bk,  ldts, rsrc, sts FROM rv_product_sts
 WHERE product_bk NOT IN ('0','-1','-2')
UNION ALL
SELECT 'ORDER',    order_bk,    ldts, rsrc, sts FROM rv_order_sts
 WHERE order_bk NOT IN ('0','-1','-2')
ORDER BY entity, business_key, ldts;
