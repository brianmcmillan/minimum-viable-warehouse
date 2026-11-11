-- TEST FIXTURE (Activity Schema only; not part of the demo sequence).
--
-- Exercises the activity paths the shared scenario never reaches:
--   * C002, deleted by tombstone in D3, is delivered again   -> restored
--   * O-100's status moves P -> S                             -> order_updated
--   * O-100's SKU-1 line is tombstoned                        -> removed_from_order
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C002','Bob Jones','bob@example.com','2026-01-06','2027-03-01','UPSERT','INCREMENTAL');
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-100','C001','S',29.49,'USD','2026-02-01 10:00','2027-03-01','UPSERT','INCREMENTAL');
INSERT INTO stg_order_line_l1(order_ref, sku, extract_dt, op, load_mode) VALUES
('O-100','SKU-1','2027-03-01','DELETE','INCREMENTAL');
