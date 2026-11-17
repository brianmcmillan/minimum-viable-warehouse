-- D3 -- CRM customer INCREMENTAL window with an explicit TOMBSTONE:
-- the extractor announces that C002 was deleted at source (op='DELETE').
-- This is how deletes travel in an incremental world -- absence never
-- deletes here, an assertion does.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C002',NULL,NULL,NULL,'2026-03-16','DELETE','INCREMENTAL');
