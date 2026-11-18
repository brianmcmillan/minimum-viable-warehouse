-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- RESTORE AFTER DELETE. C002 was deleted by the D3 tombstone. CRM now
-- delivers it again with exactly the values it had before the delete.
-- The deleted-marker row carries those same last-known values, so the
-- change compare (diff_str) sees no change: only the loader's
-- "current row is deleted" branch can reopen C002. It must close the
-- marker and insert a live version -- three rows in all -- and C002
-- reappears in v_customer.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C002','Bob Jones','bob@example.com','2026-01-06','2027-04-01','UPSERT','INCREMENTAL');
