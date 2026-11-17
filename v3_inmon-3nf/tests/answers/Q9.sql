-- Q9. After the 'P' label changes to PLACED, what does every past order read?
-- Expected: O-100=PLACED,O-101=PLACED (every version of every order).
SELECT group_concat(order_ref || '=' || status, ',') FROM (
  SELECT order_ref, status FROM orders ORDER BY order_ref, valid_from);
