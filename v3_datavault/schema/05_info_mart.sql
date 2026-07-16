-- =====================================================================
-- DV2.0 :: INFO MART  (business-facing views over the vault)
-- ---------------------------------------------------------------------
-- Column-for-column mirrors of the Focal demo's v_customer / v_product /
-- v_order, so `make demo` output is directly comparable across models.
--
-- SOFT RULES LIVE HERE. The vault stores OMS's raw status codes; the
-- P->PENDING translation happens in these views. Change the rule and
-- every row -- past and present -- reflects it instantly, because the
-- raw value was never overwritten. (The Focal demo translates at ingest
-- and needs its archive + `make rebuild` to achieve the same.)
--
-- "Current" = newest satellite row per key, gated on the status-tracking
-- satellite: a key whose latest sts is 'D' is deleted at source and
-- excluded, exactly as Focal's row_st='N' drops facts from its views.
-- =====================================================================

-- Newest satellite row per key (the standard "current sat" subquery).
CREATE VIEW v_customer_hsat_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_bk ORDER BY ldts DESC) rn
  FROM rv_customer_hsat
) WHERE rn = 1;

CREATE VIEW v_product_hsat_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY product_bk ORDER BY ldts DESC) rn
  FROM rv_product_hsat
) WHERE rn = 1;

CREATE VIEW v_order_hsat_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY order_bk ORDER BY ldts DESC) rn
  FROM rv_order_hsat
) WHERE rn = 1;

-- Latest presence assertion per key.
CREATE VIEW v_customer_sts_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_bk ORDER BY ldts DESC) rn
  FROM rv_customer_sts
) WHERE rn = 1;

CREATE VIEW v_product_sts_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY product_bk ORDER BY ldts DESC) rn
  FROM rv_product_sts
) WHERE rn = 1;

CREATE VIEW v_order_sts_current AS
SELECT * FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY order_bk ORDER BY ldts DESC) rn
  FROM rv_order_sts
) WHERE rn = 1;

---------------------------- DIMENSION VIEWS ---------------------------

CREATE VIEW dim_customer AS
SELECT h.customer_bk               AS customer_ref,
       s.full_name                 AS customer_name,
       s.email_addr                AS email,
       s.signup_date               AS signup_date
FROM rv_customer_h h
JOIN v_customer_sts_current st ON st.customer_bk = h.customer_bk AND st.sts = 'I'
LEFT JOIN v_customer_hsat_current s ON s.customer_bk = h.customer_bk;

CREATE VIEW dim_product AS
SELECT h.product_bk AS sku,
       s.prod_name  AS product_name,
       s.price      AS price,
       s.currency   AS currency
FROM rv_product_h h
JOIN v_product_sts_current st ON st.product_bk = h.product_bk AND st.sts = 'I'
LEFT JOIN v_product_hsat_current s ON s.product_bk = h.product_bk;

------------------------------ FACT VIEW -------------------------------
-- placed_by resolves through the CURRENT effectivity pairing, then
-- through dim_customer -- so a deleted customer yields NULL, matching
-- the Focal demo's v_order behaviour.

CREATE VIEW fact_order AS
SELECT h.order_bk AS order_ref,
       CASE s.status WHEN 'P' THEN 'PENDING'  WHEN 'S' THEN 'SHIPPED'
                     WHEN 'D' THEN 'DELIVERED' WHEN 'C' THEN 'CANCELLED'
                     ELSE s.status END        AS status,      -- soft rule, applied on read
       s.amount     AS amount,
       s.currency   AS currency,
       s.placed_at  AS placed_at,
       (SELECT d.customer_name FROM v_order_customer_current c
          JOIN dim_customer d ON d.customer_ref = c.customer_bk
         WHERE c.order_bk = h.order_bk)       AS placed_by
FROM rv_order_h h
JOIN v_order_sts_current st ON st.order_bk = h.order_bk AND st.sts = 'I'
LEFT JOIN v_order_hsat_current s ON s.order_bk = h.order_bk;

----------------------------- AUDIT VIEWS ------------------------------
-- Full timeline of order status: RAW next to translated, to make the
-- hard-rule / soft-rule split visible.
CREATE VIEW v_order_status_history AS
SELECT order_bk AS order_ref, ldts, rsrc,
       status AS raw_status,
       CASE status WHEN 'P' THEN 'PENDING'  WHEN 'S' THEN 'SHIPPED'
                   WHEN 'D' THEN 'DELIVERED' WHEN 'C' THEN 'CANCELLED'
                   ELSE status END AS status
FROM rv_order_hsat
ORDER BY order_bk, ldts;

-- Presence timeline per key across all three entities: when each key
-- was asserted present or deleted, and by which delivery.
CREATE VIEW v_status_history AS
SELECT 'CUSTOMER' AS entity, customer_bk AS business_key, ldts, rsrc, sts FROM rv_customer_sts
UNION ALL
SELECT 'PRODUCT',  product_bk,  ldts, rsrc, sts FROM rv_product_sts
UNION ALL
SELECT 'ORDER',    order_bk,    ldts, rsrc, sts FROM rv_order_sts
ORDER BY entity, business_key, ldts;
