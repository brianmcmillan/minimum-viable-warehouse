-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- RESTORE AFTER DELETE. C002 was deleted by the D3 tombstone. CRM now
-- delivers it again, with a new email. Two things must reopen:
--   * its existence: a new ACTIVE version of CUSTOMER_EXISTENCE (19),
--     after ACTIVE (D0) and DELETED (D3);
--   * its attributes: name, email and signup were closed (row_st 'N')
--     by the tombstone, so each gets a NEW version with row_st 'Y'.
-- C002 then reappears in v_customer with its new values.
--
-- Wide, like every delivery: one CRM.CUSTOMER row, INCREMENTAL.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C002','Bob Jones','bob@restored.com','2026-01-06','2027-04-01','UPSERT','INCREMENTAL');
