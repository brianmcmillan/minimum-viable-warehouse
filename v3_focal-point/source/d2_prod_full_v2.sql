-- D2 -- PIM product FULL snapshot v2 (extract 2026-03-02).
-- SKU-1's price changed; SKU-2 unchanged; SKU-3 has been discontinued and
-- is ABSENT -> under a FULL delivery, absence means DELETE.
INSERT INTO stg_product_l1(sku, prod_name, price, currency, extract_dt, op, load_mode) VALUES
('SKU-1','Widget', 8.99,'USD','2026-03-02','UPSERT','FULL'),
('SKU-2','Gadget',19.5 ,'USD','2026-03-02','UPSERT','FULL');
