-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
SELECT group_concat(email, '>') FROM (
  SELECT email FROM customer WHERE customer_ref = 'C001' AND is_deleted = 0 ORDER BY valid_from);
