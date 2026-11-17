-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
SELECT group_concat(email_addr, '>') FROM (
  SELECT email_addr FROM frame__crm__customer
  WHERE hk_customer = 'CRM.CUST|C001' AND change_type <> 'DELETE' ORDER BY load_ts);
