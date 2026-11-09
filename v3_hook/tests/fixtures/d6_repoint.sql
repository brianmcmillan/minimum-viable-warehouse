-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- DRIVING-KEY RE-POINT: OMS corrects order O-101 to customer C001.
-- In HOOK the relationship lives on the order row as its hk_customer
-- hook, and customer_ref is part of the order's diff -- so the re-point
-- is simply a new frame__oms__order row (change_type UPDATE) whose hook
-- now reads CRM.CUST|C001. The old row, and its CRM.CUST|C002 hook,
-- stays in the frame as history. No link, no effectivity satellite,
-- no UPDATE.
--
-- The data row is byte-identical with the sibling demos' d6 fixture.
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-101','C001','P',19.5,'USD','2026-02-02 11:30','2027-02-01','UPSERT','INCREMENTAL');
