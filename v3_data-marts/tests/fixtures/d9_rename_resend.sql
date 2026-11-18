-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- FROZEN KEY UNDER A RE-SEND. C001 is renamed (a new SCD2 version), and
-- in the same delivery OMS re-sends order O-100 with nothing changed.
-- Dimensions load first, so when the fact loader runs, C001's current
-- version is the renamed one. O-100 is not a restatement -- every value
-- matches the fact -- so its customer_key must stay frozen to the
-- version current at purchase: placed_by_at_purchase is still
-- 'Alice Smith', while placed_by_current follows the rename.
INSERT INTO stg_customer_l1(customer_id, full_name, email_addr, signup_date, extract_dt, op, load_mode) VALUES
('C001','Alice Jones','alice@example.com','2026-01-05','2027-05-01','UPSERT','INCREMENTAL');
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-100','C001','P',29.49,'USD','2026-02-01 10:00','2027-05-01','UPSERT','INCREMENTAL');
