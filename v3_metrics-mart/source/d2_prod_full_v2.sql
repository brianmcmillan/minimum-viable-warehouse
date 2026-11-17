-- D2 -- PIM product FULL snapshot (extract 2026-03-02).
-- SKU-1 price drops to 8.99; SKU-3 is discontinued (ABSENT from the full
-- snapshot) and must therefore be deleted -- absence=delete is valid for FULL.
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('PIM','PRODUCT','SKU-1','sku','SKU-1',NULL,NULL,'2026-03-02','UPSERT','FULL'),
('PIM','PRODUCT','SKU-1','prod_name','Widget',NULL,NULL,'2026-03-02','UPSERT','FULL'),
('PIM','PRODUCT','SKU-1','price',NULL,8.99,NULL,'2026-03-02','UPSERT','FULL'),
('PIM','PRODUCT','SKU-1','currency','USD',NULL,NULL,'2026-03-02','UPSERT','FULL'),
('PIM','PRODUCT','SKU-2','sku','SKU-2',NULL,NULL,'2026-03-02','UPSERT','FULL'),
('PIM','PRODUCT','SKU-2','prod_name','Gadget',NULL,NULL,'2026-03-02','UPSERT','FULL'),
('PIM','PRODUCT','SKU-2','price',NULL,19.5,NULL,'2026-03-02','UPSERT','FULL'),
('PIM','PRODUCT','SKU-2','currency','USD',NULL,NULL,'2026-03-02','UPSERT','FULL');
