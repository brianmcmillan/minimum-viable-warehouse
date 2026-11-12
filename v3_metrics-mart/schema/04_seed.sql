-- =====================================================================
-- METRICS MART :: SEED (reference rows + routing metadata)
-- ---------------------------------------------------------------------
-- The schema seed is the source of truth for reference data: a rebuild
-- recreates exactly these rows. Seed rows carry a fixed srcd_ts so a
-- rebuilt mart is identical to the ingested one.
-- =====================================================================

INSERT INTO res_type(res_type, res_type_desc, autocrt_res_flag, srcd_ts) VALUES
 ('CUSTOMER','CRM customer', 1,'2026-01-01 00:00:00'),
 ('PRODUCT', 'PIM product',  1,'2026-01-01 00:00:00'),
 ('ORDER',   'OMS order',    1,'2026-01-01 00:00:00');

-- 'P' = parent: a customer may be the parent of an order.
INSERT INTO res_type_rel(parent_res_type, child_res_type, res_type_rel, srcd_ts) VALUES
 ('CUSTOMER','ORDER','P','2026-01-01 00:00:00');

INSERT INTO value_type(value_type, value_type_desc, srcd_ts) VALUES
 ('GAUGE', 'a level observed at a moment; the newest sample is current','2026-01-01 00:00:00'),
 ('AMOUNT','a monetary amount restated on each observation',            '2026-01-01 00:00:00');

INSERT INTO metric(metric_id, value_type, metric_code, metric_name, metric_desc, unit_of_measure, srcd_ts) VALUES
 (1,'AMOUNT','amount','Order amount','Total amount of an order as OMS reports it','currency','2026-01-01 00:00:00'),
 (2,'GAUGE', 'price', 'List price',  'List price of a product as PIM reports it', 'currency','2026-01-01 00:00:00');

INSERT INTO order_status(status_code, status_name, srcd_ts) VALUES
 ('P','PENDING',  '2026-01-01 00:00:00'),
 ('S','SHIPPED',  '2026-01-01 00:00:00'),
 ('D','DELIVERED','2026-01-01 00:00:00'),
 ('C','CANCELLED','2026-01-01 00:00:00');

INSERT INTO meta_feed_map(source_system, source_entity, role, res_type,
                          group_root, group_attribute, member_attribute, member_res_type) VALUES
 ('CRM','CUSTOMER',  'RES',   'CUSTOMER',NULL,NULL,NULL,NULL),
 ('PIM','PRODUCT',   'RES',   'PRODUCT', NULL,NULL,NULL,NULL),
 ('OMS','ORDER',     'RES',   'ORDER',   NULL,NULL,NULL,NULL),
 -- An order line puts a product in the order's group: /ORDER/<order_ref>.
 ('OMS','ORDER_LINE','MEMBER',NULL,'/ORDER','order_ref','sku','PRODUCT'),
 ('OPS','CALNDR_EVENT','EVENT', NULL,NULL,NULL,NULL,NULL);

INSERT INTO meta_attribute_map(source_system, source_entity, source_attribute, target_kind,
        target_table, target_col, slot, ref_table, ref_col, ref_open, parent_res_type, metric_code) VALUES
 ('CRM','CUSTOMER','customer_ref','KEY',    NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
 ('CRM','CUSTOMER','full_name',   'RES_COL','res','res_name','value_str',NULL,NULL,NULL,NULL,NULL),
 ('CRM','CUSTOMER','email_addr',  'SUBTYPE','res_customer','email_addr', 'value_str',NULL,NULL,NULL,NULL,NULL),
 ('CRM','CUSTOMER','signup_date', 'SUBTYPE','res_customer','signup_date','value_ts', NULL,NULL,NULL,NULL,NULL),
 ('PIM','PRODUCT','sku',          'KEY',    NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
 ('PIM','PRODUCT','prod_name',    'RES_COL','res','res_name','value_str',NULL,NULL,NULL,NULL,NULL),
 ('PIM','PRODUCT','currency',     'SUBTYPE','res_product','currency_code','value_str','currency','currency_code',1,NULL,NULL),
 ('PIM','PRODUCT','price',        'METRIC', NULL,NULL,'value_num',NULL,NULL,NULL,NULL,'price'),
 ('OMS','ORDER','order_ref',      'KEY',    NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL),
 ('OMS','ORDER','customer_ref',   'PARENT', NULL,NULL,'value_str',NULL,NULL,NULL,'CUSTOMER',NULL),
 ('OMS','ORDER','status',         'SUBTYPE','res_order','status_code',  'value_str','order_status','status_code',0,NULL,NULL),
 ('OMS','ORDER','currency',       'SUBTYPE','res_order','currency_code','value_str','currency','currency_code',1,NULL,NULL),
 ('OMS','ORDER','placed_at',      'SUBTYPE','res_order','placed_at',    'value_ts', NULL,NULL,NULL,NULL,NULL),
 ('OMS','ORDER','amount',         'METRIC', NULL,NULL,'value_num',NULL,NULL,NULL,NULL,'amount');

-- ------------------------------ CALENDAR ------------------------------

INSERT INTO cal_evt_type(cal_evt_type, cal_evt_type_desc, srcd_ts) VALUES
 ('HOLIDAY',    'Public holiday',                    '2026-01-01 00:00:00'),
 ('MAINTENANCE','Planned maintenance window',        '2026-01-01 00:00:00'),
 ('BLACKOUT',   'Change freeze',                     '2026-01-01 00:00:00'),
 ('REVIEW',     'Scheduled review',                  '2026-01-01 00:00:00'),
 ('PROMOTION',  'Sales promotion',                   '2026-01-01 00:00:00');

-- CALNDR covers 2026 and 2027. Recurring events expand only inside it.
INSERT INTO calndr(calndr_date, day_of_week, occur_of_month, last_occur_flag,
                   day_of_month, month_end_flag, week_of_year, month, year, srcd_ts)
WITH RECURSIVE d(dt) AS (
  SELECT '2026-01-01' UNION ALL SELECT date(dt,'+1 day') FROM d WHERE dt < '2027-12-31')
SELECT dt,
       (CAST(strftime('%w',dt) AS INTEGER) + 6) % 7 + 1,
       (CAST(strftime('%d',dt) AS INTEGER) - 1) / 7 + 1,
       CASE WHEN date(dt,'+7 days') > date(dt,'start of month','+1 month','-1 day') THEN 1 ELSE 0 END,
       CAST(strftime('%d',dt) AS INTEGER),
       CASE WHEN strftime('%d', date(dt,'+1 day')) = '01' THEN 1 ELSE 0 END,
       CAST(strftime('%W',dt) AS INTEGER),
       CAST(strftime('%m',dt) AS INTEGER),
       CAST(strftime('%Y',dt) AS INTEGER),
       '2026-01-01 00:00:00'
FROM d;

INSERT INTO meta_attribute_map(source_system, source_entity, source_attribute, target_kind,
        target_table, target_col, slot) VALUES
 ('OPS','CALNDR_EVENT','event_code',      'KEY',      NULL,NULL,NULL),
 ('OPS','CALNDR_EVENT','group_path',      'EVENT_COL','calndr_event_stg','group_path',      'value_str'),
 ('OPS','CALNDR_EVENT','event_grp',       'EVENT_COL','calndr_event_stg','event_grp_code',  'value_str'),
 ('OPS','CALNDR_EVENT','cal_evt_type',    'EVENT_COL','calndr_event_stg','cal_evt_type',    'value_str'),
 ('OPS','CALNDR_EVENT','inheritance_flag','EVENT_COL','calndr_event_stg','inheritance_flag','value_num'),
 ('OPS','CALNDR_EVENT','event_start_dt',  'EVENT_COL','calndr_event_stg','event_start_dt',  'value_ts'),
 ('OPS','CALNDR_EVENT','event_start_tm',  'EVENT_COL','calndr_event_stg','event_start_tm',  'value_str'),
 ('OPS','CALNDR_EVENT','duration',        'EVENT_COL','calndr_event_stg','duration',        'value_num'),
 ('OPS','CALNDR_EVENT','active_start_dt', 'EVENT_COL','calndr_event_stg','active_start_dt', 'value_ts'),
 ('OPS','CALNDR_EVENT','active_end_dt',   'EVENT_COL','calndr_event_stg','active_end_dt',   'value_ts'),
 ('OPS','CALNDR_EVENT','days_of_week',    'EVENT_COL','calndr_event_stg','days_of_week',    'value_str'),
 ('OPS','CALNDR_EVENT','occurs_of_month', 'EVENT_COL','calndr_event_stg','occurs_of_month', 'value_str'),
 ('OPS','CALNDR_EVENT','days_of_month',   'EVENT_COL','calndr_event_stg','days_of_month',   'value_str'),
 ('OPS','CALNDR_EVENT','month_end_flag',  'EVENT_COL','calndr_event_stg','month_end_flag',  'value_num'),
 ('OPS','CALNDR_EVENT','months',          'EVENT_COL','calndr_event_stg','months',          'value_str'),
 ('OPS','CALNDR_EVENT','year',            'EVENT_COL','calndr_event_stg','year',            'value_num'),
 ('OPS','CALNDR_EVENT','entered_by',      'EVENT_COL','calndr_event_stg','entered_by',      'value_str'),
 ('OPS','CALNDR_EVENT','event_desc',      'EVENT_COL','calndr_event_stg','event_desc',      'value_str');
