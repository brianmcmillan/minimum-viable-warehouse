-- Q9. After the 'P' label changes to PLACED, what does every past order read?
-- Expected: O-100=PLACED,O-101=PLACED. Every row of the historized status
-- attribute, labelled through the OST knot on read.
SELECT group_concat(order_ref || '=' || label, ',') FROM (
  SELECT r.Order_Reference AS order_ref, k.Order_Status AS label
  FROM OD_OST_Order_Status s
  JOIN OST_OrderStatus k ON k.OST_ID = s.OST_ID
  JOIN OD_REF_Order_Reference r ON r.OD_ID = s.OD_ID
  ORDER BY r.Order_Reference, s.ChangedAt);
