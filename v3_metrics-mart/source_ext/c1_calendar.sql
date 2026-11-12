-- C1 -- OPS calendar, FULL initial load (extract 2027-01-04).
-- Not part of the shared corpus: source/ stays byte-identical with the
-- Focal and Anchor demos. Five events, one at each level a calendar
-- event can target, in three event groups:
--   NEWYEAR      HOLIDAYS-2027  /TYPE, inherited    every resource   one-off 2027-01-01
--   PIM-MAINT    OPS-2027       /TYPE/PRODUCT       every product    Sundays in January 2027
--   ORDER-FREEZE OPS-2027       /ORDER, inherited   order products   the last day of December 2027
--   C001-REVIEW  (none)         /RES/CUSTOMER/C001  one customer     month ends, January-June 2027
--   SPRING-SALE  PROMOS-2026    /TYPE/PRODUCT       every product    every day, 1-7 March 2026
-- SPRING-SALE covers D2's 2026-03-02 price samples, so the demo can
-- show a sample next to the event that explains it.
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('OPS','CALNDR_EVENT','NEWYEAR','event_code','NEWYEAR',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','NEWYEAR','group_path','/TYPE',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','NEWYEAR','cal_evt_type','HOLIDAY',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','NEWYEAR','event_grp','HOLIDAYS-2027',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','NEWYEAR','inheritance_flag',NULL,1,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','NEWYEAR','event_start_dt',NULL,NULL,'2027-01-01','2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','NEWYEAR','duration',NULL,1440,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','NEWYEAR','event_desc','New Year''s Day',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','PIM-MAINT','event_code','PIM-MAINT',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','PIM-MAINT','group_path','/TYPE/PRODUCT',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','PIM-MAINT','cal_evt_type','MAINTENANCE',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','PIM-MAINT','event_grp','OPS-2027',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','PIM-MAINT','inheritance_flag',NULL,0,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','PIM-MAINT','event_start_tm','02:00:00',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','PIM-MAINT','duration',NULL,120,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','PIM-MAINT','active_start_dt',NULL,NULL,'2027-01-01','2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','PIM-MAINT','active_end_dt',NULL,NULL,'2027-01-31','2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','PIM-MAINT','days_of_week','NNNNNNY',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','PIM-MAINT','event_desc','Catalogue maintenance window',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','ORDER-FREEZE','event_code','ORDER-FREEZE',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','ORDER-FREEZE','group_path','/ORDER',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','ORDER-FREEZE','cal_evt_type','BLACKOUT',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','ORDER-FREEZE','event_grp','OPS-2027',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','ORDER-FREEZE','inheritance_flag',NULL,1,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','ORDER-FREEZE','month_end_flag',NULL,1,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','ORDER-FREEZE','months','NNNNNNNNNNNY',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','ORDER-FREEZE','year',NULL,2027,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','ORDER-FREEZE','event_desc','Year-end change freeze',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','event_code','C001-REVIEW',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','group_path','/RES/CUSTOMER/C001',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','cal_evt_type','REVIEW',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','inheritance_flag',NULL,0,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','event_start_tm','09:00:00',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','duration',NULL,60,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','active_start_dt',NULL,NULL,'2027-01-01','2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','active_end_dt',NULL,NULL,'2027-06-30','2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','month_end_flag',NULL,1,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','C001-REVIEW','event_desc','Account review',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','SPRING-SALE','event_code','SPRING-SALE',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','SPRING-SALE','group_path','/TYPE/PRODUCT',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','SPRING-SALE','cal_evt_type','PROMOTION',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','SPRING-SALE','event_grp','PROMOS-2026',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','SPRING-SALE','inheritance_flag',NULL,0,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','SPRING-SALE','duration',NULL,1440,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','SPRING-SALE','active_start_dt',NULL,NULL,'2026-03-01','2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','SPRING-SALE','active_end_dt',NULL,NULL,'2026-03-07','2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','SPRING-SALE','days_of_week','YYYYYYY',NULL,NULL,'2027-01-04','UPSERT','FULL'),
('OPS','CALNDR_EVENT','SPRING-SALE','event_desc','Spring sale',NULL,NULL,'2027-01-04','UPSERT','FULL');
