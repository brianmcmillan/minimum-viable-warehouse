-- Q2. Which customers are deleted?  Expected after D5: C002,C003
-- A deletion is the current dimension version carrying the deleted marker.
SELECT group_concat(customer_ref, ',') FROM (
  SELECT customer_ref FROM dim_customer WHERE is_current = 1 AND is_deleted = 1 ORDER BY customer_ref);
