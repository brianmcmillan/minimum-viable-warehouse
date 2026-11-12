-- D5 -- CRM customer YEARLY FULL reconciliation (extract 2026-12-31).
-- A normally-INCREMENTAL feed sends a full snapshot. It contains only the
-- customers still live at source (C001). C003, added via an incremental
-- window but since gone, is ABSENT -> deleted by the reconciliation.
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('CRM','CUSTOMER','C001','customer_ref','C001',NULL,NULL,'2026-12-31','UPSERT','FULL'),
('CRM','CUSTOMER','C001','full_name','Alice Smith',NULL,NULL,'2026-12-31','UPSERT','FULL'),
('CRM','CUSTOMER','C001','email_addr','alice@newmail.com',NULL,NULL,'2026-12-31','UPSERT','FULL'),
('CRM','CUSTOMER','C001','signup_date',NULL,NULL,'2026-01-05','2026-12-31','UPSERT','FULL');
