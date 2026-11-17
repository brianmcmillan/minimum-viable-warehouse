-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- A RANGE join: the customer row valid when the EDW first recorded the order.
SELECT placed_by_as_recorded FROM v_order_as_recorded
WHERE order_ref = 'O-101'
  AND recorded_at = (SELECT MIN(valid_from) FROM orders WHERE order_ref = 'O-101');
