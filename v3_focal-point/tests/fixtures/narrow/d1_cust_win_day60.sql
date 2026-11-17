-- D1 -- CRM customer 14-day INCREMENTAL window (~day 60, extract 2026-03-02).
-- Contains ONLY customers that changed in the window: C001's email changed.
-- C002 has not changed in 60 days and is therefore ABSENT. It must NOT be deleted.
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('CRM','CUSTOMER','C001','customer_ref','C001',NULL,NULL,'2026-03-02','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C001','full_name','Alice Smith',NULL,NULL,'2026-03-02','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C001','email_addr','alice@newmail.com',NULL,NULL,'2026-03-02','UPSERT','INCREMENTAL'),
('CRM','CUSTOMER','C001','signup_date',NULL,NULL,'2026-01-05','2026-03-02','UPSERT','INCREMENTAL');
