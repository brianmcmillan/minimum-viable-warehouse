-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- RESTORE AFTER DELETE. C002 was deleted by the D3 tombstone (an EST
-- assertion of DELETED). CRM now delivers it again with exactly the
-- values it had before the delete. The historized attributes already
-- hold those values, so they append nothing; only the existence
-- synthesis can bring C002 back, by asserting EXISTS for a key whose
-- latest EST is DELETED. Existence history: EXISTS > DELETED > EXISTS,
-- and C002 is back in v_customer.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C002','Bob Jones','bob@example.com','2026-01-06','2027-04-01','UPSERT','INCREMENTAL');
