-- =====================================================================
-- ANCHOR :: LATEST PERSPECTIVES + comparison views
-- ---------------------------------------------------------------------
-- Anchor's read model: no end dates are ever stored, so "current" is
-- computed -- latest row per anchor per historized attribute. The
-- official tooling generates these (latest / point-in-time views);
-- here they are hand-written for three entities, which is the honest
-- glimpse of why that tooling exists.
--
-- v_customer / v_product / v_order mirror the sibling demos' business
-- views column-for-column. Deleted entities are excluded via the
-- latest EST (existence) attribute -- presence is DATA here, so the
-- ghost-row problem cannot arise structurally.
-- =====================================================================

-- Latest row per anchor for each historized attribute.
CREATE VIEW lCU_NAM AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY CU_ID ORDER BY ChangedAt DESC) rn FROM CU_NAM_Customer_Name) WHERE rn=1;
CREATE VIEW lCU_EML AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY CU_ID ORDER BY ChangedAt DESC) rn FROM CU_EML_Customer_Email) WHERE rn=1;
CREATE VIEW lCU_EST AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY CU_ID ORDER BY ChangedAt DESC) rn FROM CU_EST_Customer_Existence) WHERE rn=1;
CREATE VIEW lPR_NAM AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY PR_ID ORDER BY ChangedAt DESC) rn FROM PR_NAM_Product_Name) WHERE rn=1;
CREATE VIEW lPR_PRC AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY PR_ID ORDER BY ChangedAt DESC) rn FROM PR_PRC_Product_Price) WHERE rn=1;
CREATE VIEW lPR_CUR AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY PR_ID ORDER BY ChangedAt DESC) rn FROM PR_CUR_Product_Currency) WHERE rn=1;
CREATE VIEW lPR_EST AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY PR_ID ORDER BY ChangedAt DESC) rn FROM PR_EST_Product_Existence) WHERE rn=1;
CREATE VIEW lOD_AMT AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY OD_ID ORDER BY ChangedAt DESC) rn FROM OD_AMT_Order_Amount) WHERE rn=1;
CREATE VIEW lOD_CUR AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY OD_ID ORDER BY ChangedAt DESC) rn FROM OD_CUR_Order_Currency) WHERE rn=1;
CREATE VIEW lOD_OST AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY OD_ID ORDER BY ChangedAt DESC) rn FROM OD_OST_Order_Status) WHERE rn=1;
CREATE VIEW lOD_EST AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY OD_ID ORDER BY ChangedAt DESC) rn FROM OD_EST_Order_Existence) WHERE rn=1;
CREATE VIEW lOD_placed_CU AS SELECT * FROM (SELECT *, ROW_NUMBER() OVER
  (PARTITION BY OD_ID ORDER BY ChangedAt DESC) rn FROM OD_placed_CU_by) WHERE rn=1;

------------------------- business perspectives -------------------------

CREATE VIEW v_customer AS
SELECT r.Customer_Reference AS customer_ref,
       n.Customer_Name      AS customer_name,
       e.Customer_Email     AS email,
       s.Customer_SignupDate AS signup_date
FROM CU_Customer a
JOIN CU_REF_Customer_Reference r ON r.CU_ID = a.CU_ID
JOIN lCU_EST x ON x.CU_ID = a.CU_ID AND x.EST_ID = 1     -- EXISTS
LEFT JOIN lCU_NAM n ON n.CU_ID = a.CU_ID
LEFT JOIN lCU_EML e ON e.CU_ID = a.CU_ID
LEFT JOIN CU_SGN_Customer_SignupDate s ON s.CU_ID = a.CU_ID;

CREATE VIEW v_product AS
SELECT r.Product_Reference AS sku,
       n.Product_Name      AS product_name,
       p.Product_Price     AS price,
       c.Currency          AS currency
FROM PR_Product a
JOIN PR_REF_Product_Reference r ON r.PR_ID = a.PR_ID
JOIN lPR_EST x ON x.PR_ID = a.PR_ID AND x.EST_ID = 1
LEFT JOIN lPR_NAM n ON n.PR_ID = a.PR_ID
LEFT JOIN lPR_PRC p ON p.PR_ID = a.PR_ID
LEFT JOIN lPR_CUR pc ON pc.PR_ID = a.PR_ID
LEFT JOIN CUR_Currency c ON c.CUR_ID = pc.CUR_ID;

CREATE VIEW v_order AS
SELECT r.Order_Reference AS order_ref,
       ost.Order_Status  AS status,          -- label from the knot, on read
       amt.Order_Amount  AS amount,
       cur.Currency      AS currency,
       plc.Order_PlacedAt AS placed_at,
       (SELECT c.customer_name FROM lOD_placed_CU t
          JOIN CU_REF_Customer_Reference cr ON cr.CU_ID = t.CU_ID
          JOIN v_customer c ON c.customer_ref = cr.Customer_Reference
         WHERE t.OD_ID = a.OD_ID)            AS placed_by
FROM OD_Order a
JOIN OD_REF_Order_Reference r ON r.OD_ID = a.OD_ID
JOIN lOD_EST x ON x.OD_ID = a.OD_ID AND x.EST_ID = 1
LEFT JOIN lOD_AMT amt ON amt.OD_ID = a.OD_ID
LEFT JOIN lOD_CUR oc  ON oc.OD_ID = a.OD_ID
LEFT JOIN CUR_Currency cur ON cur.CUR_ID = oc.CUR_ID
LEFT JOIN lOD_OST os  ON os.OD_ID = a.OD_ID
LEFT JOIN OST_OrderStatus ost ON ost.OST_ID = os.OST_ID
LEFT JOIN OD_PLC_Order_PlacedAt plc ON plc.OD_ID = a.OD_ID;

--------------------------- timeline views ------------------------------
-- Attribute-grain history: one attribute's changes, nothing else's.
CREATE VIEW v_customer_email_history AS
SELECT r.Customer_Reference AS customer_ref, e.Customer_Email, e.ChangedAt
FROM CU_EML_Customer_Email e
JOIN CU_REF_Customer_Reference r ON r.CU_ID = e.CU_ID
ORDER BY r.Customer_Reference, e.ChangedAt;

-- Presence timeline across all three anchors.
CREATE VIEW v_existence_history AS
SELECT 'CUSTOMER' AS entity, r.Customer_Reference AS business_key,
       k.ExistenceStatus, x.ChangedAt
FROM CU_EST_Customer_Existence x
JOIN CU_REF_Customer_Reference r ON r.CU_ID = x.CU_ID
JOIN EST_ExistenceStatus k ON k.EST_ID = x.EST_ID
UNION ALL
SELECT 'PRODUCT', r.Product_Reference, k.ExistenceStatus, x.ChangedAt
FROM PR_EST_Product_Existence x
JOIN PR_REF_Product_Reference r ON r.PR_ID = x.PR_ID
JOIN EST_ExistenceStatus k ON k.EST_ID = x.EST_ID
UNION ALL
SELECT 'ORDER', r.Order_Reference, k.ExistenceStatus, x.ChangedAt
FROM OD_EST_Order_Existence x
JOIN OD_REF_Order_Reference r ON r.OD_ID = x.OD_ID
JOIN EST_ExistenceStatus k ON k.EST_ID = x.EST_ID
ORDER BY entity, business_key, ChangedAt;

-- Tie history with LEAD-computed end dates (cf. the DV effsat view).
CREATE VIEW v_order_customer_history AS
SELECT o.Order_Reference AS order_ref, c.Customer_Reference AS customer_ref,
       t.ChangedAt AS start_ts,
       COALESCE(LEAD(t.ChangedAt) OVER (PARTITION BY t.OD_ID ORDER BY t.ChangedAt),
                '9999-12-31 23:59:59') AS end_ts,
       CASE WHEN LEAD(t.ChangedAt) OVER (PARTITION BY t.OD_ID ORDER BY t.ChangedAt)
            IS NULL THEN 1 ELSE 0 END AS iscurrent
FROM OD_placed_CU_by t
JOIN OD_REF_Order_Reference o ON o.OD_ID = t.OD_ID
JOIN CU_REF_Customer_Reference c ON c.CU_ID = t.CU_ID;
