-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- RESTORE AFTER DELETE. C002 was deleted by the D3 tombstone (a DELETE
-- row in frame__crm__customer). CRM now delivers it again with exactly
-- the values it had before the delete. The delta engine compares with
-- the latest frame row -- the DELETE -- so it must write a new INSERT
-- row: change types INSERT > DELETE > INSERT, and C002 is back in
-- v_customer.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C002','Bob Jones','bob@example.com','2026-01-06','2027-04-01','UPSERT','INCREMENTAL');
