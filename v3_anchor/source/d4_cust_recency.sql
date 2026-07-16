-- D4 -- CRM customer INCREMENTAL window that adds C003, and (to exercise
-- recency de-dup) delivers C003's email TWICE with different extract_ts.
-- The values are chosen so a naive MAX(value) would pick the OLDER one
-- ('old@x.com' > 'new@x.com' lexically); correct recency picks 'new@x.com'.
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('CRM','CUSTOMER','C003','customer_ref','C003',NULL,NULL,'2026-04-02','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C003','full_name','Carol Diaz',NULL,NULL,'2026-04-02','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C003','signup_date',NULL,NULL,'2026-03-10','2026-04-02','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C003','email_addr','old@x.com',NULL,NULL,'2026-04-01','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C003','email_addr','new@x.com',NULL,NULL,'2026-04-02','UPSERT','INCREMENTAL');
