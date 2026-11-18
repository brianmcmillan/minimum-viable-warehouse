-- Q9. After the 'P' label changes to PLACED, what does every past order read?
-- Expected: O-100=PLACED,O-101=PLACED. Every order activity that carries a
-- status, decoded on read under the rule in force now.
SELECT group_concat(a.link || '=' || COALESCE(r.status_name, 'UNKNOWN(' || a.st || ')'), ',') FROM (
  SELECT link, json_extract(feature_json, '$.status') AS st FROM customer_stream
  WHERE activity IN ('placed_order', 'order_updated') AND json_extract(feature_json, '$.status') IS NOT NULL
  ORDER BY link, ts, _seq) a
LEFT JOIN ref_oms_order_status r ON r.status_code = a.st;
