-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
-- Every open version of the CUSTOMER_EMAIL context (type_key 11).
SELECT group_concat(d.val_str, '>') FROM (
  SELECT val_str FROM customer_desc d JOIN customer_idfr i ON i.customer_key = d.customer_key
  WHERE i.customer_idfr = 'C001' AND d.type_key = 11 AND d.row_st = 'Y'
  ORDER BY d.eff_tmstp, d.ver_tmstp) d;
