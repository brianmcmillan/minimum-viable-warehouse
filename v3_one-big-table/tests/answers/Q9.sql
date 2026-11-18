-- Q9. After the 'P' label changes to PLACED, what does every past order read?
-- Expected: O-100=PLACED,O-101=PLACED. The latest table holds one row per
-- order; the label comes from the CASE in v_order, read on query.
SELECT group_concat(order_ref || '=' || status, ',') FROM (
  SELECT order_ref, status FROM v_order ORDER BY order_ref);
