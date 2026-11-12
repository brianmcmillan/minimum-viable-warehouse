-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- PIM corrects the 2027-03-01 price of SKU-2 from 21.5 to 20.5 (same
-- extract_ts, so the same METRIC_SAMPLE key) and adds an observation
-- two days later in the same week. The correction OVERWRITES the
-- sample: the mart keeps no correction history, the archive keeps both.
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('PIM','PRODUCT','SKU-2','price',NULL,20.5,NULL,'2027-03-01','UPSERT','INCREMENTAL'),
('PIM','PRODUCT','SKU-2','price',NULL,22.5,NULL,'2027-03-03','UPSERT','INCREMENTAL');
