-- D3 -- CRM customer INCREMENTAL delivery carrying an explicit tombstone.
-- C002 is deleted at source. In an INCREMENTAL feed a delete MUST be an
-- explicit op='DELETE' fact (absence would be ignored).
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('CRM','CUSTOMER','C002','_tombstone',NULL,NULL,NULL,'2026-03-16','DELETE','INCREMENTAL');
