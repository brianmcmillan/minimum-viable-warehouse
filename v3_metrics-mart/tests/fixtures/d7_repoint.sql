-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- DRIVING-ROLE RE-POINT, narrow restatement of the wide d6_repoint used
-- by the DV and Kimball demos: OMS corrects order O-101 to customer
-- C001, every other attribute unchanged. The historized tie appends a
-- new pairing (superseding O-101->C002 by ChangedAt); restatement
-- control keeps every attribute table silent. A relationship event and
-- nothing else -- Anchor's native equivalent of the DV effectivity sat.
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OMS','ORDER','O-101','order_ref','O-101',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-101','customer_ref','C001',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-101','status','P',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-101','amount',NULL,19.5,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-101','currency','USD',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('OMS','ORDER','O-101','placed_at',NULL,NULL,'2026-02-02 11:30','2027-02-01','UPSERT','INCREMENTAL');
