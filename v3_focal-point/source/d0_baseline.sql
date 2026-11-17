-- D0 BASELINE -- FULL initial load of every feed (extract 2026-02-05).
-- Wide restatement of the Focal demo's d0_baseline.sql: identical keys,
-- values, extract dates and modes; the shape matches each source extract.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C001','Alice Smith','alice@example.com','2026-01-05','2026-02-05','UPSERT','FULL'),
('C002','Bob Jones'  ,'bob@example.com'  ,'2026-01-06','2026-02-05','UPSERT','FULL');

INSERT INTO stg_product_l1(sku, prod_name, price, currency, extract_dt, op, load_mode) VALUES
('SKU-1','Widget', 9.99,'USD','2026-02-05','UPSERT','FULL'),
('SKU-2','Gadget',19.5 ,'USD','2026-02-05','UPSERT','FULL'),
('SKU-3','Gizmo' , 5.0 ,'EUR','2026-02-05','UPSERT','FULL');

INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-100','C001','P',29.49,'USD','2026-02-01 10:00','2026-02-05','UPSERT','FULL'),
('O-101','C002','P',19.5 ,'USD','2026-02-02 11:30','2026-02-05','UPSERT','FULL');

INSERT INTO stg_order_line_l1(order_ref, sku, extract_dt, op, load_mode) VALUES
('O-100','SKU-1','2026-02-05','UPSERT','FULL'),
('O-100','SKU-2','2026-02-05','UPSERT','FULL'),
('O-101','SKU-2','2026-02-05','UPSERT','FULL');
