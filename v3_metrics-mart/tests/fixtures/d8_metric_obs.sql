-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- A narrow delivery that carries ONE attribute of one product: a new
-- price observation for SKU-2, nothing else. It exercises three things
-- the shared corpus never does on its own:
--   * a partial narrow delivery -- the absent attributes (prod_name,
--     currency) mean "no change", not NULL;
--   * a sample that is a new observation of a CHANGED value;
--   * weekly aggregation across two samples in one week (the D8C
--     correction fixture adds the second).
INSERT INTO source_landing_stage(source_system,source_entity,business_key,attribute_name,value_str,value_num,value_ts,extract_ts,op,load_mode) VALUES
('PIM','PRODUCT','SKU-2','price',NULL,21.5,NULL,'2027-03-01','UPSERT','INCREMENTAL');
