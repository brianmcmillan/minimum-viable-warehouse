-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- PIM corrects the 2027-03-01 price of SKU-2 from 21.5 to 20.5 (same
-- extract_ts, so the same METRIC_SAMPLE key) and adds an observation
-- two days later in the same week. The correction OVERWRITES the
-- sample: the mart keeps no correction history, the archive keeps both.
--
-- Wide, like every delivery: each row restates SKU-2's whole record (name
-- and currency unchanged), so only the price observations are new.
INSERT INTO stg_product_l1(sku, prod_name, price, currency, extract_dt, op, load_mode) VALUES
('SKU-2','Gadget',20.5,'USD','2027-03-01','UPSERT','INCREMENTAL'),
('SKU-2','Gadget',22.5,'USD','2027-03-03','UPSERT','INCREMENTAL');
