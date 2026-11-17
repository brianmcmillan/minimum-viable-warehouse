-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
SELECT group_concat(email_addr, '>') FROM (
  SELECT email_addr FROM rv_customer_hsat WHERE customer_bk = 'C001' ORDER BY ldts);
