-- TEST FIXTURE (not part of the demo sequence).
--
-- A FULL calendar delivery that lists only C001-REVIEW, unchanged.
-- ORDER-FREEZE, PIM-MAINT and SPRING-SALE are absent from a FULL
-- delivery, so they are deleted. C001-REVIEW is restated as it was and writes nothing.
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OPS','CALNDR_EVENT','C001-REVIEW','event_code','C001-REVIEW',NULL,NULL,'2027-01-18','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','group_path','/RES/CUSTOMER/C001',NULL,NULL,'2027-01-18','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','cal_evt_type','REVIEW',NULL,NULL,'2027-01-18','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','inheritance_flag',NULL,0,NULL,'2027-01-18','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','event_start_tm','09:00:00',NULL,NULL,'2027-01-18','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','duration',NULL,60,NULL,'2027-01-18','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','active_start_dt',NULL,NULL,'2027-01-01','2027-01-18','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','active_end_dt',NULL,NULL,'2027-06-30','2027-01-18','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','month_end_flag',NULL,1,NULL,'2027-01-18','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','event_desc','Account review',NULL,NULL,'2027-01-18','UPSERT','FULL');
