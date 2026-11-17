-- Q9. After the 'P' label changes to PLACED, what does every past order read?
-- Expected: O-100=PLACED,O-101=PLACED. One fact row per order; the label
-- comes from the Type 1 decode dimension.
SELECT group_concat(order_ref || '=' || status, ',') FROM (
  SELECT order_ref, status FROM mart_orders ORDER BY order_ref);
