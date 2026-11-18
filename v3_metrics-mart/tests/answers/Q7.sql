-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- The order's parent resource, by its kept last-known name. The parent is
-- updated in place on a re-point, so this answers "as at purchase" only
-- until the order is re-pointed.
SELECT p.res_name FROM res o JOIN res p ON p.res_id = o.parent_res
WHERE o.res_type = 'ORDER' AND o.res_code = 'O-101';
