-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- Exercises the ONE case where the recency dedup falls back to physical row
-- order: the same attribute delivered twice for the same key with an
-- IDENTICAL extract_ts. `ORDER BY extract_ts DESC, rowid DESC` then decides
-- on rowid, so the LAST row in the file wins -- 'last@x.com'.
--
-- This is what makes seq_nbr load-bearing in the archive. Replay must
-- restore source_landing_stage in seq_nbr order or the tiebreak inverts and
-- the rebuilt warehouse disagrees with the ingested one.
--
-- d4_cust_recency.sql cannot cover this: its two emails carry different
-- extract_ts values, so extract_ts alone settles it and rowid never engages.
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('CRM','CUSTOMER','C004','customer_ref','C004',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C004','full_name','Dana Ellis',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C004','signup_date',NULL,NULL,'2027-01-15','2027-02-01','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C004','email_addr','first@x.com',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C004','email_addr','last@x.com',NULL,NULL,'2027-02-01','UPSERT','INCREMENTAL');
