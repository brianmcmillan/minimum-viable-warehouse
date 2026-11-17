-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- Three lifecycle events in one delivery:
--   * C002, tombstoned by D3, is delivered again        -> restored
--   * order O-102 arrives for customer C777, whom CRM
--     has never delivered                               -> stub auto-created
--   * the O-100~SKU-1 order line is tombstoned          -> membership deleted
--
-- Wide, like every delivery: a wide row restates the whole record. C002
-- comes back with the signup_date it already had; O-102 is new and has no
-- placed_at, so that column is empty (NULL: no value, ever).
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C002','Bob Jones','bob@example.com','2026-01-06','2027-04-01','UPSERT','INCREMENTAL');
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-102','C777','S',5.25,'GBP',NULL,'2027-04-01','UPSERT','INCREMENTAL');
INSERT INTO stg_order_line_l1(order_ref, sku, extract_dt, op, load_mode) VALUES
('O-100','SKU-1','2027-04-01','DELETE','INCREMENTAL');
