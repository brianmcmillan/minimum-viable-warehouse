-- =====================================================================
-- ACTIVITY SCHEMA :: THE STREAMS  (Activity Schema 2.0, on SQLite)
-- ---------------------------------------------------------------------
-- Everything the warehouse knows is a row in an activity stream: an
-- entity doing something at a moment in time. One stream per entity
-- type, as the spec requires:
--
--   customer_stream  -- entity = a CRM customer. Customer lifecycle and
--                       profile changes, and every order activity (an
--                       order is something a customer does; `link`
--                       carries the order_ref).
--   product_stream   -- entity = a PIM product (the spec's column is
--                       still named `customer`; here it holds the SKU).
--                       Catalogue changes, and `was_ordered` for each
--                       order line (`link` = order_ref).
--
-- Spec columns: activity_id, ts, customer, activity, feature_json
-- (required); anonymous_customer_id, revenue_impact, link (optional).
-- `_`-prefixed columns are implementation-specific, which the spec
-- allows: _seq (load order, the tiebreak for equal ts), _load_ts and
-- _record_source (lineage, as in every sibling demo).
--
-- Activities are IMMUTABLE (the spec's own rule). A changed attribute
-- is a new activity; a delete is a new activity. The triggers below
-- refuse UPDATE and DELETE outright -- there is no unlock path.
--
-- There are no entity tables. The spec allows one per stream for
-- current metadata, but it would be a mutable copy of what the streams
-- already say; current state is a view (v_*_state below).
-- =====================================================================

CREATE TABLE customer_stream (
    activity_id           TEXT    PRIMARY KEY,
    ts                    TEXT    NOT NULL,
    customer              TEXT,
    activity              TEXT    NOT NULL,
    anonymous_customer_id TEXT,
    feature_json          TEXT    NOT NULL DEFAULT '{}',
    revenue_impact        REAL,
    link                  TEXT,
    _seq                  INTEGER NOT NULL UNIQUE,
    _load_ts              TEXT    NOT NULL,
    _record_source        TEXT    NOT NULL,
    CHECK (customer IS NOT NULL OR anonymous_customer_id IS NOT NULL)
);

CREATE TABLE product_stream (
    activity_id           TEXT    PRIMARY KEY,
    ts                    TEXT    NOT NULL,
    customer              TEXT,
    activity              TEXT    NOT NULL,
    anonymous_customer_id TEXT,
    feature_json          TEXT    NOT NULL DEFAULT '{}',
    revenue_impact        REAL,
    link                  TEXT,
    _seq                  INTEGER NOT NULL UNIQUE,
    _load_ts              TEXT    NOT NULL,
    _record_source        TEXT    NOT NULL,
    CHECK (customer IS NOT NULL OR anonymous_customer_id IS NOT NULL)
);

CREATE TRIGGER trg_cs_nu BEFORE UPDATE ON customer_stream
BEGIN SELECT RAISE(ABORT,'activities are immutable'); END;
CREATE TRIGGER trg_cs_nd BEFORE DELETE ON customer_stream
BEGIN SELECT RAISE(ABORT,'activities are immutable'); END;
CREATE TRIGGER trg_ps_nu BEFORE UPDATE ON product_stream
BEGIN SELECT RAISE(ABORT,'activities are immutable'); END;
CREATE TRIGGER trg_ps_nd BEFORE DELETE ON product_stream
BEGIN SELECT RAISE(ABORT,'activities are immutable'); END;

-- The catalogue of activities this warehouse emits, and what each one
-- is authoritative for (the spec: an activity stores only the metadata
-- it owns). The test suite asserts no stream holds an activity that is
-- missing from here.
CREATE TABLE activity_catalog (
    stream    TEXT NOT NULL,
    activity  TEXT NOT NULL,
    ts_source TEXT NOT NULL,   -- where `ts` comes from
    meaning   TEXT NOT NULL,
    PRIMARY KEY (stream, activity)
);
INSERT INTO activity_catalog VALUES
 ('customer_stream','signed_up',          'signup_date (event time)', 'first sighting; feature = the profile as first observed'),
 ('customer_stream','updated_name',       'extract_dt (observed)',    'full_name changed'),
 ('customer_stream','updated_email',      'extract_dt (observed)',    'email_addr changed'),
 ('customer_stream','updated_signup_date','extract_dt (observed)',    'signup_date restated'),
 ('customer_stream','was_deleted',        'extract_dt / snapshot',    'tombstone, or absent from a FULL snapshot'),
 ('customer_stream','restored',           'extract_dt (observed)',    'delivered again after a delete; feature = full profile'),
 ('customer_stream','placed_order',       'placed_at (event time)',   'order first seen; link = order_ref'),
 ('customer_stream','order_updated',      'extract_dt (observed)',    'status/amount/currency/placed_at restated'),
 ('customer_stream','order_reassigned',   'extract_dt (observed)',    'order moved to this customer; feature.from_customer'),
 ('customer_stream','order_deleted',      'extract_dt / snapshot',    'order tombstoned or absent from a FULL snapshot'),
 ('customer_stream','order_restored',     'extract_dt (observed)',    'order delivered again after a delete'),
 ('product_stream', 'added',              'extract_dt (observed)',    'first sighting; feature = the product as first observed'),
 ('product_stream', 'updated_name',       'extract_dt (observed)',    'prod_name changed'),
 ('product_stream', 'updated_price',      'extract_dt (observed)',    'price changed'),
 ('product_stream', 'updated_currency',   'extract_dt (observed)',    'currency changed'),
 ('product_stream', 'discontinued',       'extract_dt / snapshot',    'tombstone, or absent from a FULL snapshot'),
 ('product_stream', 'restored',           'extract_dt (observed)',    'delivered again after a delete'),
 ('product_stream', 'was_ordered',        'order placed_at (event)',  'appears on an order; link = order_ref'),
 ('product_stream', 'removed_from_order', 'extract_dt / snapshot',    'order line tombstoned or absent from a FULL snapshot');

-- Soft rule, applied on read: the streams keep OMS's raw status code.
CREATE TABLE ref_oms_order_status (
    status_code TEXT PRIMARY KEY,
    status_name TEXT NOT NULL
);
INSERT INTO ref_oms_order_status VALUES
 ('P','PENDING'),('S','SHIPPED'),('D','DELIVERED'),('C','CANCELLED');

-- =====================================================================
-- CURRENT STATE, DERIVED FROM THE STREAMS
-- ---------------------------------------------------------------------
-- The loader compares each delivery against these views to decide what
-- happened; the read model builds on them. "Current" is the spec's
-- LAST EVER relationship: the newest activity by (ts, _seq).
-- Attribute values live in feature_json under the source column's name,
-- so the newest activity carrying a key is that attribute's value.
-- =====================================================================

CREATE VIEW v_customer_state AS
WITH life AS (
  SELECT customer, activity, ts,
         ROW_NUMBER() OVER (PARTITION BY customer ORDER BY ts DESC, _seq DESC) AS rn
  FROM customer_stream
  WHERE activity IN ('signed_up','restored','was_deleted')),
attr AS (
  SELECT s.customer, j.key AS attr, j.value AS val,
         ROW_NUMBER() OVER (PARTITION BY s.customer, j.key ORDER BY s.ts DESC, s._seq DESC) AS rn
  FROM customer_stream s, json_each(s.feature_json) j
  WHERE s.activity IN ('signed_up','restored','updated_name','updated_email','updated_signup_date'))
SELECT l.customer AS customer_id,
       CASE WHEN l.activity = 'was_deleted' THEN 0 ELSE 1 END AS alive,
       l.ts AS since,
       (SELECT val FROM attr a WHERE a.customer = l.customer AND a.attr = 'full_name'   AND a.rn = 1) AS full_name,
       (SELECT val FROM attr a WHERE a.customer = l.customer AND a.attr = 'email_addr'  AND a.rn = 1) AS email_addr,
       (SELECT val FROM attr a WHERE a.customer = l.customer AND a.attr = 'signup_date' AND a.rn = 1) AS signup_date
FROM life l WHERE l.rn = 1;

CREATE VIEW v_product_state AS
WITH life AS (
  SELECT customer, activity,
         ROW_NUMBER() OVER (PARTITION BY customer ORDER BY ts DESC, _seq DESC) AS rn
  FROM product_stream
  WHERE activity IN ('added','restored','discontinued')),
attr AS (
  SELECT s.customer, j.key AS attr, j.value AS val,
         ROW_NUMBER() OVER (PARTITION BY s.customer, j.key ORDER BY s.ts DESC, s._seq DESC) AS rn
  FROM product_stream s, json_each(s.feature_json) j
  WHERE s.activity IN ('added','restored','updated_name','updated_price','updated_currency'))
SELECT l.customer AS sku,
       CASE WHEN l.activity = 'discontinued' THEN 0 ELSE 1 END AS alive,
       (SELECT val FROM attr a WHERE a.customer = l.customer AND a.attr = 'prod_name' AND a.rn = 1) AS prod_name,
       (SELECT val FROM attr a WHERE a.customer = l.customer AND a.attr = 'price'     AND a.rn = 1) AS price,
       (SELECT val FROM attr a WHERE a.customer = l.customer AND a.attr = 'currency'  AND a.rn = 1) AS currency
FROM life l WHERE l.rn = 1;

-- Orders are not an entity here: they are activities in the customer
-- stream, tied together by `link`. Owner = the customer on the order's
-- newest activity (every order activity is written to its owner's
-- stream at that moment).
CREATE VIEW v_order_state AS
WITH ord AS (
  SELECT link, customer, activity,
         ROW_NUMBER() OVER (PARTITION BY link ORDER BY ts DESC, _seq DESC) AS rn
  FROM customer_stream
  WHERE activity IN ('placed_order','order_updated','order_reassigned','order_deleted','order_restored')),
life AS (
  SELECT link, activity,
         ROW_NUMBER() OVER (PARTITION BY link ORDER BY ts DESC, _seq DESC) AS rn
  FROM customer_stream
  WHERE activity IN ('placed_order','order_restored','order_deleted')),
attr AS (
  SELECT s.link, j.key AS attr, j.value AS val,
         ROW_NUMBER() OVER (PARTITION BY s.link, j.key ORDER BY s.ts DESC, s._seq DESC) AS rn
  FROM customer_stream s, json_each(s.feature_json) j
  WHERE s.activity IN ('placed_order','order_updated','order_restored'))
SELECT o.link AS order_ref,
       o.customer AS customer_ref,
       CASE WHEN l.activity = 'order_deleted' THEN 0 ELSE 1 END AS alive,
       (SELECT val FROM attr a WHERE a.link = o.link AND a.attr = 'status'    AND a.rn = 1) AS status,
       (SELECT val FROM attr a WHERE a.link = o.link AND a.attr = 'amount'    AND a.rn = 1) AS amount,
       (SELECT val FROM attr a WHERE a.link = o.link AND a.attr = 'currency'  AND a.rn = 1) AS currency,
       (SELECT val FROM attr a WHERE a.link = o.link AND a.attr = 'placed_at' AND a.rn = 1) AS placed_at
FROM ord o JOIN life l ON l.link = o.link AND l.rn = 1
WHERE o.rn = 1;

CREATE VIEW v_order_line_state AS
SELECT order_ref, sku, CASE WHEN activity = 'removed_from_order' THEN 0 ELSE 1 END AS on_order
FROM (
  SELECT link AS order_ref, customer AS sku, activity,
         ROW_NUMBER() OVER (PARTITION BY link, customer ORDER BY ts DESC, _seq DESC) AS rn
  FROM product_stream
  WHERE activity IN ('was_ordered','removed_from_order'))
WHERE rn = 1;
