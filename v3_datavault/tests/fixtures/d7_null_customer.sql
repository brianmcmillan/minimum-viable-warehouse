-- TEST FIXTURE (not part of the demo sequence in source/).
--
-- NULL LINK END AND A KEY WITH NO SATELLITE ROW.
--
-- O-102 arrives with customer_ref NULL. An order's customer is a
-- required relationship, so stage 2 maps the null to the reserved key
-- '-1': the link and the effectivity satellite pair O-102 with '-1',
-- and the info mart's customer views never show it.
--
-- O-103 names customer C900, whom CRM has never sent. The hub gains
-- C900 as a link end, with no row in either customer satellite, so its
-- CPIT pointers land on the ghost row '0'.
--
-- Each order has one line, so the bridge gains two rows.
INSERT INTO stg_order_l1(order_ref, customer_ref, status, amount, currency, placed_at, extract_dt, op, load_mode) VALUES
('O-102', NULL,  'P', 12.0, 'USD', '2027-03-01 09:00', '2027-03-01', 'UPSERT', 'INCREMENTAL'),
('O-103', 'C900','S', 40.0, 'USD', '2027-03-01 10:00', '2027-03-01', 'UPSERT', 'INCREMENTAL');

INSERT INTO stg_order_line_l1(order_ref, sku, extract_dt, op, load_mode) VALUES
('O-102', 'SKU-1', '2027-03-01', 'UPSERT', 'INCREMENTAL'),
('O-103', 'SKU-2', '2027-03-01', 'UPSERT', 'INCREMENTAL');
