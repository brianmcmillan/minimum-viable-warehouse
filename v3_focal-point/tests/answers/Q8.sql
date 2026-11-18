-- Q8. Who owns O-101 now?  Expected after the re-point: Alice Smith (and nobody else)
-- Every PLACED_BY pairing whose latest version is active, by the customer's
-- latest name -- deleted customers included, so a second owner shows.
WITH pairs AS (
  SELECT x.customer_key, x.row_st, ROW_NUMBER() OVER (
           PARTITION BY x.order_key, x.customer_key ORDER BY x.eff_tmstp DESC, x.ver_tmstp DESC) AS rn
  FROM order_customer_x x JOIN order_idfr o ON o.order_key = x.order_key
  WHERE o.order_idfr = 'O-101' AND x.type_key = 90)
SELECT group_concat(name, ',') FROM (
  SELECT (SELECT d.val_str FROM customer_desc d
          WHERE d.customer_key = p.customer_key AND d.type_key = 10 AND d.row_st = 'Y'
          ORDER BY d.eff_tmstp DESC LIMIT 1) AS name
  FROM pairs p WHERE p.rn = 1 AND p.row_st = 'Y' ORDER BY p.customer_key);
