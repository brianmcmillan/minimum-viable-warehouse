-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- DRIVING-KEY RE-POINT: OMS corrects order O-101 to customer C001,
-- every other attribute unchanged. This is the KNOWN GAP fixture: the
-- other five demos handle it (effectivity sat, fact update, order
-- version, historized tie, latest-wins); Focal's load_rel.sh inserts
-- the new pair and leaves the old one ACTIVE -- one order, two live
-- customers. The suite's GAP section asserts the desired behaviour as
-- expected failures; the suggested fix is printed with them.
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OMS','ORDER','O-101','order_ref','O-101',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-101','customer_ref','C001',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-101','status','P',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-101','amount',NULL,19.5,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-101','currency','USD',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-101','placed_at',NULL,NULL,'2026-02-02 11:30','2027-02-01','UPSERT','INCREMENTAL');
