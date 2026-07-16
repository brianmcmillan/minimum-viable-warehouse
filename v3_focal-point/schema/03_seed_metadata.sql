-- =====================================================================
-- SEED THE METADATA (canonical variant)
-- Entities, atomic contexts, attributes, relationships, and value
-- translations are IDENTICAL to the wide version. Only the source
-- mapping differs: it references source_system + source_entity +
-- attribute_name instead of physical source tables/columns.
-- =====================================================================

INSERT INTO meta_entity(entity_id, definition, key_col) VALUES
 ('CUSTOMER','A person or organisation that places orders','customer_key'),
 ('PRODUCT' ,'A sellable item in the catalogue','product_key'),
 ('ORDER'   ,'A purchase transaction placed by a customer','order_key');

INSERT INTO meta_atomic_context(type_key, entity_id, context_name, definition) VALUES
 (10,'CUSTOMER','CUSTOMER_NAME' ,'The customer''s display name'),
 (11,'CUSTOMER','CUSTOMER_EMAIL','The customer''s email address'),
 (12,'CUSTOMER','CUSTOMER_SIGNUP','When the customer signed up'),
 (20,'PRODUCT' ,'PRODUCT_NAME'  ,'The product display name'),
 (21,'PRODUCT' ,'PRODUCT_PRICE' ,'List price -- a NUMBER plus its CURRENCY (one atomic fact)'),
 (30,'ORDER'   ,'ORDER_STATUS'  ,'Current fulfilment status of the order'),
 (31,'ORDER'   ,'ORDER_AMOUNT'  ,'Order total -- amount plus currency (one atomic fact)'),
 (32,'ORDER'   ,'ORDER_PLACED'  ,'When the order was placed');

INSERT INTO meta_attribute(type_key, attr_name, phys_column, data_type) VALUES
 (10,'CUSTOMER_NAME'  ,'VAL_STR'  ,'STRING'),
 (11,'CUSTOMER_EMAIL' ,'VAL_STR'  ,'STRING'),
 (12,'CUSTOMER_SIGNUP','STA_TMSTP','START_TIMESTAMP'),
 (20,'PRODUCT_NAME'   ,'VAL_STR'  ,'STRING'),
 (21,'PRODUCT_PRICE'  ,'VAL_NUM'  ,'NUMBER'),
 (21,'PRODUCT_CURRENCY','UOM'     ,'UNIT'),
 (30,'ORDER_STATUS'   ,'VAL_STR'  ,'STRING'),
 (31,'ORDER_AMOUNT'   ,'VAL_NUM'  ,'NUMBER'),
 (31,'ORDER_CURRENCY' ,'UOM'      ,'UNIT'),
 (32,'ORDER_PLACED'   ,'STA_TMSTP','START_TIMESTAMP');

INSERT INTO meta_relationship(type_key, rel_name, source_entity, target_entity, x_table) VALUES
 (90,'PLACED_BY','ORDER','CUSTOMER','order_customer_x'),
 (91,'CONTAINS' ,'ORDER','PRODUCT' ,'order_product_x');

-- ---------------------------------------------------------------------
-- CANONICAL SOURCE MAP: keyed on (source_system, source_entity, attribute)
-- Note how each entity now advertises the SYSTEM it came from -- useful
-- for key/consolidation integration and provenance.
-- ---------------------------------------------------------------------
INSERT INTO meta_source_map
 (map_id, entity_id, type_key, source_system, source_entity, role, source_attribute, phys_column, default_value) VALUES
-- CUSTOMER  (from CRM)
 (1 ,'CUSTOMER',NULL,'CRM','CUSTOMER','IDFR',NULL        ,NULL      ,NULL ),
 (2 ,'CUSTOMER',10  ,'CRM','CUSTOMER','DESC','full_name' ,'VAL_STR' ,NULL ),
 (3 ,'CUSTOMER',11  ,'CRM','CUSTOMER','DESC','email_addr','VAL_STR' ,NULL ),
 (4 ,'CUSTOMER',12  ,'CRM','CUSTOMER','DESC','signup_date','STA_TMSTP',NULL),
-- PRODUCT  (from PIM)
 (5 ,'PRODUCT' ,NULL,'PIM','PRODUCT' ,'IDFR',NULL        ,NULL      ,NULL ),
 (6 ,'PRODUCT' ,20  ,'PIM','PRODUCT' ,'DESC','prod_name' ,'VAL_STR' ,NULL ),
 (7 ,'PRODUCT' ,21  ,'PIM','PRODUCT' ,'DESC','price'     ,'VAL_NUM' ,NULL ),
 (8 ,'PRODUCT' ,21  ,'PIM','PRODUCT' ,'DESC','currency'  ,'UOM'     ,'USD'),
-- ORDER  (from OMS)
 (9 ,'ORDER'   ,NULL,'OMS','ORDER'   ,'IDFR',NULL        ,NULL      ,NULL ),
 (10,'ORDER'   ,30  ,'OMS','ORDER'   ,'DESC','status'    ,'VAL_STR' ,NULL ),
 (11,'ORDER'   ,31  ,'OMS','ORDER'   ,'DESC','amount'    ,'VAL_NUM' ,NULL ),
 (12,'ORDER'   ,31  ,'OMS','ORDER'   ,'DESC','currency'  ,'UOM'     ,'USD'),
 (13,'ORDER'   ,32  ,'OMS','ORDER'   ,'DESC','placed_at' ,'STA_TMSTP',NULL);

INSERT INTO meta_value_map(type_key, source_value, target_value) VALUES
 (30,'P','PENDING'),
 (30,'S','SHIPPED'),
 (30,'D','DELIVERED'),
 (30,'C','CANCELLED');

-- Relationships: both ends are attributes on the feed row.
INSERT INTO meta_rel_map(type_key, source_system, source_entity, source_key_attr, target_key_attr) VALUES
 (90,'OMS','ORDER'     ,'order_ref','customer_ref'),
 (91,'OMS','ORDER_LINE','order_ref','sku');

-- Declared default ingestion strategy per feed.
--   CRM customers arrive as 14-day INCREMENTAL windows.
--   OMS orders / order-lines arrive as 45-day INCREMENTAL windows.
--   PIM products arrive as a FULL snapshot every run.
INSERT INTO meta_source_feed(source_system, source_entity, ingestion_strategy) VALUES
 ('CRM','CUSTOMER'  ,'INCREMENTAL'),
 ('PIM','PRODUCT'   ,'FULL'),
 ('OMS','ORDER'     ,'INCREMENTAL'),
 ('OMS','ORDER_LINE','INCREMENTAL');
