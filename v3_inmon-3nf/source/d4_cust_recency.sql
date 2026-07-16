-- D4 -- CRM customer INCREMENTAL window that adds C003, delivered TWICE
-- with different extract_dt (a re-extract inside the same delivery).
-- The values are chosen so naive MAX() would pick the OLDER email
-- ('old@x.com' > 'new@x.com' lexically); correct recency dedup at stage 2
-- keeps the newest ROW: 'new@x.com'.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C003','Carol Diaz','old@x.com','2026-03-10','2026-04-01','UPSERT','INCREMENTAL'),
('C003','Carol Diaz','new@x.com','2026-03-10','2026-04-02','UPSERT','INCREMENTAL');
