-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- RESTORE AFTER DELETE. C002 was deleted by the D3 tombstone (a 'D' row
-- in rv_customer_sts). CRM now delivers it again with exactly the
-- values it had before the delete. Its newest rv_customer_hsat row
-- already holds those values, so the satellite writes nothing; only the
-- status-tracking load can reopen C002, by writing 'I' for a key whose
-- current status is 'D'. Status history: I > D > I, and C002 is back in
-- dim_customer.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C002','Bob Jones','bob@example.com','2026-01-06','2027-04-01','UPSERT','INCREMENTAL');
