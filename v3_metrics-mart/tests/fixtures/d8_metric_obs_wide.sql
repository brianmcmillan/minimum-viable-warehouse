-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- The wide-delivery form of the d8_metric_obs.sql price observation: a
-- new price for SKU-2 on 2027-03-01, with its name and currency restated
-- unchanged (a wide row carries the whole record). It goes through
-- load_feed.sh and the archive like any delivery, so the correction
-- (d8c), the weekly aggregates and every rebuild after it see the same
-- sample the narrow fixture used to provide.
--
-- d8_metric_obs.sql (narrow, unchanged) still tests the partial-delivery
-- rule -- absent attributes mean "no change" -- straight into the narrow
-- stage (level 2).
INSERT INTO stg_product_l1(sku, prod_name, price, currency, extract_dt, op, load_mode) VALUES
('SKU-2','Gadget',21.5,'USD','2027-03-01','UPSERT','INCREMENTAL');
