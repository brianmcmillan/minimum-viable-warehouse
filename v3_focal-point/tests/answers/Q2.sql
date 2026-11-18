-- Q2. Which customers are deleted?  Expected after D5: C002,C003
-- The current CUSTOMER_EXISTENCE fact per key.
SELECT group_concat(customer_ref, ',') FROM (
  SELECT customer_ref FROM v_customer_status WHERE existence = 'DELETED' ORDER BY customer_ref);
