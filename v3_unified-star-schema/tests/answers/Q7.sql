-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- RAW: presentation model: the bridge records the current owner; the purchase-time owner lives in the insert-only core (v_order_as_recorded over core_order and core_customer)
-- As-of on load time, from the core: the order's first core row, read
-- against the customer core row valid at that moment.
SELECT placed_by_as_recorded FROM v_order_as_recorded
WHERE order_ref = 'O-101'
  AND recorded_at = (SELECT MIN(recorded_at) FROM v_order_as_recorded WHERE order_ref = 'O-101');
