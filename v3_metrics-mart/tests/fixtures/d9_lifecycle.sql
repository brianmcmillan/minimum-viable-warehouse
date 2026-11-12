-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- Three lifecycle events in one delivery:
--   * C002, tombstoned by D3, is delivered again        -> restored
--   * order O-102 arrives for customer C777, whom CRM
--     has never delivered                               -> stub auto-created
--   * the O-100~SKU-1 order line is tombstoned          -> membership deleted
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('CRM','CUSTOMER','C002','customer_ref','C002',NULL,NULL,'2027-04-01','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C002','full_name','Bob Jones',NULL,NULL,'2027-04-01','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C002','email_addr','bob@example.com',NULL,NULL,'2027-04-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-102','order_ref','O-102',NULL,NULL,'2027-04-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-102','customer_ref','C777',NULL,NULL,'2027-04-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-102','status','S',NULL,NULL,'2027-04-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-102','amount',NULL,5.25,NULL,'2027-04-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-102','currency','GBP',NULL,NULL,'2027-04-01','UPSERT','INCREMENTAL'),
('OMS','ORDER_LINE','O-100~SKU-1','_tombstone',NULL,NULL,NULL,'2027-04-01','DELETE','INCREMENTAL');
