-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
-- The SCD2 versions of the customer dimension.
SELECT group_concat(email, '>') FROM (
  SELECT email FROM dim_customer WHERE customer_ref = 'C001' AND is_deleted = 0 ORDER BY row_eff_ts);
