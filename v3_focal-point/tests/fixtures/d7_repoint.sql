-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- DRIVING-KEY RE-POINT: OMS corrects order O-101 to customer C001,
-- every other attribute unchanged. This is the KNOWN GAP fixture: the
-- other five demos handle it (effectivity sat, fact update, order
-- version, historized tie, latest-wins); Focal's load_rel.sh inserts
-- the new pair and leaves the old one ACTIVE -- one order, two live
-- customers. The suite's GAP section asserts the desired behaviour as
-- expected failures; the suggested fix is printed with them.
--
-- Wide, like every delivery: one OMS.ORDER row. stage_narrow.sh unpivots
-- it into the same six key/value rows the narrow version of this fixture
-- carried.
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-101','C001','P',19.5,'USD','2026-02-02 11:30','2027-02-01','UPSERT','INCREMENTAL');
