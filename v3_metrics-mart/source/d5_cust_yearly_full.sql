-- D5 -- CRM customer YEARLY FULL reconciliation (extract 2026-12-31).
-- A normally-INCREMENTAL feed sends a full snapshot. It contains only the
-- customers still live at source (C001). C003, added via an incremental
-- window but since gone, is ABSENT -> deleted by the reconciliation.
-- C002 was already tombstoned and stays deleted.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C001','Alice Smith','alice@newmail.com','2026-01-05','2026-12-31','UPSERT','FULL');
