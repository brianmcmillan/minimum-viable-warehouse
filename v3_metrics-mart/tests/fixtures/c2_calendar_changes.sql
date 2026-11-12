-- TEST FIXTURE (not part of the demo sequence).
--
-- An INCREMENTAL calendar delivery with two changes:
--   * ORDER-FREEZE carries ONE attribute: inheritance_flag = 0. Every
--     other attribute keeps its value. /ORDER has no direct members, so
--     without inheritance the freeze now reaches no resource.
--   * NEWYEAR is tombstoned.
--   * PIM-MAINT moves to a new event group, MAINT-2027, which the
--     delivery creates.
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OPS','CALNDR_EVENT','ORDER-FREEZE','inheritance_flag',NULL,0,NULL,'2027-01-11','UPSERT','INCREMENTAL'),
('OPS','CALNDR_EVENT','NEWYEAR','_tombstone',NULL,NULL,NULL,'2027-01-11','DELETE','INCREMENTAL'),
('OPS','CALNDR_EVENT','PIM-MAINT','event_grp','MAINT-2027',NULL,NULL,'2027-01-11','UPSERT','INCREMENTAL');
