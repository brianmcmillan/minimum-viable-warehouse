-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- RESTORE AFTER DELETE. C002 was deleted by the D3 tombstone. CRM now
-- delivers it again with exactly the values it had before the delete.
-- OBT derives "deleted" from the log on every refresh: C002's latest
-- mention is now this UPSERT, not the tombstone, so the refresh must
-- count it alive again -- whatever happened to it before.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C002','Bob Jones','bob@example.com','2026-01-06','2027-04-01','UPSERT','INCREMENTAL');
