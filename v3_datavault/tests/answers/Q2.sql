-- Q2. Which customers are deleted?  Expected after D5: C002,C003
-- Presence is a fact: the latest status-tracking row per key says 'D'.
SELECT group_concat(customer_bk, ',') FROM (
  SELECT customer_bk FROM v_customer_sts_current WHERE sts = 'D' ORDER BY customer_bk);
