-- D1 -- CRM customer 14-day INCREMENTAL window (~day 60, extract 2026-03-02).
-- Contains ONLY customers that changed in the window: C001's email changed.
-- C002 has not changed in 60 days and is therefore ABSENT. It must NOT be deleted.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C001','Alice Smith','alice@newmail.com','2026-01-05','2026-03-02','UPSERT','INCREMENTAL');
