-- =====================================================================
-- ANCHOR :: THE 6NF CONSTELLATION
-- ---------------------------------------------------------------------
-- 3 anchors + 3 knots + 16 attribute tables + 2 ties = 24 tables for
-- the same data the Focal demo holds in 4 generic ones. That contrast
-- is the point: Anchor and Focal share the same goals -- attribute-
-- grain history, insert-only, non-destructive evolution -- and take
-- opposite physical routes. Here every attribute gets its OWN table
-- with a PROPERLY TYPED column (Product_Price is REAL, not a val_num
-- slot), schema evolution is a new table (never ALTER), and meaning
-- lives in the schema itself rather than in metadata rows.
--
-- Conventions (after anchormodeling.com, simplified where noted):
--   anchors     XX_Name           surrogate + metadata only
--   attributes  XX_MMM_Anchor_Attr  one per attribute;
--               historized ones carry ChangedAt (PK: id + ChangedAt),
--               static ones do not (PK: id). No end dates, ever --
--               "latest" is computed on the way out.
--   knots       MMM_Name          immutable shared value domains
--   ties        XX_role_YY_role   relationships; historized ties are
--               latest-per-driving-role (first role drives)
-- Deviations, documented: column names drop the canonical mnemonic
-- prefix (CU_NAM_CU_ID -> CU_ID) for join legibility; OST is a
-- "described" knot carrying code + label so the shared P->PENDING
-- rule-change test works; mnemonic OD (not OR) because bare OR is a
-- SQL keyword; Metadata_LDTS stands in for Anchor's metadata construct.
-- =====================================================================

------------------------------- ANCHORS --------------------------------
-- An anchor is ONLY identity: surrogate + metadata. Even the business
-- key is an attribute (the *_REF tables below) -- identity and
-- identification are separate facts.

CREATE TABLE CU_Customer (
    CU_ID         INTEGER PRIMARY KEY,
    Metadata_LDTS TEXT NOT NULL
);
CREATE TABLE PR_Product (
    PR_ID         INTEGER PRIMARY KEY,
    Metadata_LDTS TEXT NOT NULL
);
CREATE TABLE OD_Order (
    OD_ID         INTEGER PRIMARY KEY,
    Metadata_LDTS TEXT NOT NULL
);

-------------------------------- KNOTS ---------------------------------
-- Immutable shared value domains. A knot member is never updated by a
-- loader; unknown codes FAIL the load (a knot is a closed domain --
-- an unseen value is a data-quality error, not a new member).

CREATE TABLE EST_ExistenceStatus (          -- presence, modeled as data
    EST_ID INTEGER PRIMARY KEY,
    ExistenceStatus TEXT NOT NULL UNIQUE
);
INSERT INTO EST_ExistenceStatus VALUES (1,'EXISTS'),(2,'DELETED');

CREATE TABLE OST_OrderStatus (              -- "described" knot: code + label
    OST_ID INTEGER PRIMARY KEY,
    Status_Code  TEXT NOT NULL UNIQUE,      -- raw source value; loader resolves this
    Order_Status TEXT NOT NULL              -- business label; views read this
);
INSERT INTO OST_OrderStatus VALUES
 (1,'P','PENDING'),(2,'S','SHIPPED'),(3,'D','DELIVERED'),(4,'C','CANCELLED');

CREATE TABLE CUR_Currency (
    CUR_ID INTEGER PRIMARY KEY,
    Currency TEXT NOT NULL UNIQUE
);
INSERT INTO CUR_Currency VALUES (1,'EUR'),(2,'USD');

--------------------------- CUSTOMER ATTRIBUTES -------------------------

CREATE TABLE CU_REF_Customer_Reference (    -- static: the business key
    CU_ID INTEGER PRIMARY KEY REFERENCES CU_Customer(CU_ID),
    Customer_Reference TEXT NOT NULL UNIQUE,
    Metadata_LDTS TEXT NOT NULL
);
CREATE TABLE CU_NAM_Customer_Name (         -- historized
    CU_ID INTEGER NOT NULL REFERENCES CU_Customer(CU_ID),
    Customer_Name TEXT,
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (CU_ID, ChangedAt)
);
CREATE TABLE CU_EML_Customer_Email (        -- historized
    CU_ID INTEGER NOT NULL REFERENCES CU_Customer(CU_ID),
    Customer_Email TEXT,
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (CU_ID, ChangedAt)
);
CREATE TABLE CU_SGN_Customer_SignupDate (   -- static: a signup never moves
    CU_ID INTEGER PRIMARY KEY REFERENCES CU_Customer(CU_ID),
    Customer_SignupDate TEXT,
    Metadata_LDTS TEXT NOT NULL
);
CREATE TABLE CU_EST_Customer_Existence (    -- knotted, historized: presence as data
    CU_ID INTEGER NOT NULL REFERENCES CU_Customer(CU_ID),
    EST_ID INTEGER NOT NULL REFERENCES EST_ExistenceStatus(EST_ID),
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (CU_ID, ChangedAt)
);

---------------------------- PRODUCT ATTRIBUTES -------------------------

CREATE TABLE PR_REF_Product_Reference (
    PR_ID INTEGER PRIMARY KEY REFERENCES PR_Product(PR_ID),
    Product_Reference TEXT NOT NULL UNIQUE,
    Metadata_LDTS TEXT NOT NULL
);
CREATE TABLE PR_NAM_Product_Name (
    PR_ID INTEGER NOT NULL REFERENCES PR_Product(PR_ID),
    Product_Name TEXT,
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (PR_ID, ChangedAt)
);
CREATE TABLE PR_PRC_Product_Price (         -- REAL, not a generic slot
    PR_ID INTEGER NOT NULL REFERENCES PR_Product(PR_ID),
    Product_Price REAL,
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (PR_ID, ChangedAt)
);
CREATE TABLE PR_CUR_Product_Currency (      -- knotted, historized
    PR_ID INTEGER NOT NULL REFERENCES PR_Product(PR_ID),
    CUR_ID INTEGER NOT NULL REFERENCES CUR_Currency(CUR_ID),
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (PR_ID, ChangedAt)
);
CREATE TABLE PR_EST_Product_Existence (
    PR_ID INTEGER NOT NULL REFERENCES PR_Product(PR_ID),
    EST_ID INTEGER NOT NULL REFERENCES EST_ExistenceStatus(EST_ID),
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (PR_ID, ChangedAt)
);

----------------------------- ORDER ATTRIBUTES --------------------------

CREATE TABLE OD_REF_Order_Reference (
    OD_ID INTEGER PRIMARY KEY REFERENCES OD_Order(OD_ID),
    Order_Reference TEXT NOT NULL UNIQUE,
    Metadata_LDTS TEXT NOT NULL
);
CREATE TABLE OD_AMT_Order_Amount (
    OD_ID INTEGER NOT NULL REFERENCES OD_Order(OD_ID),
    Order_Amount REAL,
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (OD_ID, ChangedAt)
);
CREATE TABLE OD_CUR_Order_Currency (
    OD_ID INTEGER NOT NULL REFERENCES OD_Order(OD_ID),
    CUR_ID INTEGER NOT NULL REFERENCES CUR_Currency(CUR_ID),
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (OD_ID, ChangedAt)
);
CREATE TABLE OD_PLC_Order_PlacedAt (        -- static
    OD_ID INTEGER PRIMARY KEY REFERENCES OD_Order(OD_ID),
    Order_PlacedAt TEXT,
    Metadata_LDTS TEXT NOT NULL
);
CREATE TABLE OD_OST_Order_Status (          -- knotted, historized
    OD_ID INTEGER NOT NULL REFERENCES OD_Order(OD_ID),
    OST_ID INTEGER NOT NULL REFERENCES OST_OrderStatus(OST_ID),
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (OD_ID, ChangedAt)
);
CREATE TABLE OD_EST_Order_Existence (
    OD_ID INTEGER NOT NULL REFERENCES OD_Order(OD_ID),
    EST_ID INTEGER NOT NULL REFERENCES EST_ExistenceStatus(EST_ID),
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (OD_ID, ChangedAt)
);

-------------------------------- TIES ----------------------------------

CREATE TABLE OD_placed_CU_by (              -- historized; OD is the driving role
    OD_ID INTEGER NOT NULL REFERENCES OD_Order(OD_ID),
    CU_ID INTEGER NOT NULL REFERENCES CU_Customer(CU_ID),
    ChangedAt TEXT NOT NULL,
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (OD_ID, ChangedAt)          -- one customer per order at a time
);
CREATE TABLE OD_part_PR_of (                -- static; pairs are additive facts
    OD_ID INTEGER NOT NULL REFERENCES OD_Order(OD_ID),
    PR_ID INTEGER NOT NULL REFERENCES PR_Product(PR_ID),
    Metadata_LDTS TEXT NOT NULL,
    PRIMARY KEY (OD_ID, PR_ID)
);

-------------------------- LOADER METADATA SEEDS ------------------------

INSERT INTO meta_anchor_map VALUES
 ('CU','CU_Customer','CU_ID','CU_REF_Customer_Reference','Customer_Reference',
  'CU_EST_Customer_Existence','CRM','CUSTOMER','customer_ref'),
 ('PR','PR_Product','PR_ID','PR_REF_Product_Reference','Product_Reference',
  'PR_EST_Product_Existence','PIM','PRODUCT','sku'),
 ('OD','OD_Order','OD_ID','OD_REF_Order_Reference','Order_Reference',
  'OD_EST_Order_Existence','OMS','ORDER','order_ref');

INSERT INTO meta_attribute_map
 (source_system, source_entity, source_attribute, anchor_mn,
  attr_table, attr_col, slot, historized, knot_table, knot_id_col, knot_val_col) VALUES
 ('CRM','CUSTOMER','full_name'  ,'CU','CU_NAM_Customer_Name'      ,'Customer_Name'      ,'value_str',1,NULL,NULL,NULL),
 ('CRM','CUSTOMER','email_addr' ,'CU','CU_EML_Customer_Email'     ,'Customer_Email'     ,'value_str',1,NULL,NULL,NULL),
 ('CRM','CUSTOMER','signup_date','CU','CU_SGN_Customer_SignupDate','Customer_SignupDate','value_ts' ,0,NULL,NULL,NULL),
 ('PIM','PRODUCT' ,'prod_name'  ,'PR','PR_NAM_Product_Name'       ,'Product_Name'       ,'value_str',1,NULL,NULL,NULL),
 ('PIM','PRODUCT' ,'price'      ,'PR','PR_PRC_Product_Price'      ,'Product_Price'      ,'value_num',1,NULL,NULL,NULL),
 ('PIM','PRODUCT' ,'currency'   ,'PR','PR_CUR_Product_Currency'   ,'CUR_ID'             ,'value_str',1,'CUR_Currency','CUR_ID','Currency'),
 ('OMS','ORDER'   ,'status'     ,'OD','OD_OST_Order_Status'       ,'OST_ID'             ,'value_str',1,'OST_OrderStatus','OST_ID','Status_Code'),
 ('OMS','ORDER'   ,'amount'     ,'OD','OD_AMT_Order_Amount'       ,'Order_Amount'       ,'value_num',1,NULL,NULL,NULL),
 ('OMS','ORDER'   ,'currency'   ,'OD','OD_CUR_Order_Currency'     ,'CUR_ID'             ,'value_str',1,'CUR_Currency','CUR_ID','Currency'),
 ('OMS','ORDER'   ,'placed_at'  ,'OD','OD_PLC_Order_PlacedAt'     ,'Order_PlacedAt'     ,'value_ts' ,0,NULL,NULL,NULL);

INSERT INTO meta_tie_map VALUES
 ('OD_placed_CU_by',1,'OMS','ORDER'     ,'OD','order_ref','OD_ID','CU','customer_ref','CU_ID'),
 ('OD_part_PR_of'  ,0,'OMS','ORDER_LINE','OD','order_ref','OD_ID','PR','sku'        ,'PR_ID');
