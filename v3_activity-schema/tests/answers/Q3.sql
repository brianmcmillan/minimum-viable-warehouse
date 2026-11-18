-- Q3. What has C001's email been, oldest first?  Expected: alice@example.com>alice@newmail.com
-- Every activity that asserts an email: the signup, then each updated_email.
SELECT group_concat(json_extract(feature_json, '$.email_addr'), '>') FROM (
  SELECT feature_json FROM customer_stream
  WHERE customer = 'C001' AND activity IN ('signed_up', 'updated_email', 'restored')
    AND json_extract(feature_json, '$.email_addr') IS NOT NULL
  ORDER BY ts, _seq);
