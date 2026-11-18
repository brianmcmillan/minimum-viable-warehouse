-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- As-of on load time, from the core: the order's first core row, read
-- against the customer core row valid at that moment.
SELECT placed_by_as_recorded FROM v_order_as_recorded
WHERE order_ref = 'O-101'
  AND recorded_at = (SELECT MIN(recorded_at) FROM v_order_as_recorded WHERE order_ref = 'O-101');
