-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
-- RAW: presentation model: the star holds current values only; email history lives in the insert-only core (core_customer)
-- History lives in the insert-only core; the star holds current rows only.
SELECT group_concat(email_addr, '>') FROM (
  SELECT email_addr FROM core_customer
  WHERE customer_id = 'C001' AND change_type <> 'DELETE' ORDER BY load_ts);
