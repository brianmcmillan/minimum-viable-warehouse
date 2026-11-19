-- Q7. Who placed O-101, as at purchase?  Expected: Bob Jones
-- v_order_first_owner: the order's first logged owner, as at that delivery.
.read v3_one-big-table/schema/03_log_views.sql
SELECT full_name FROM v_order_first_owner WHERE order_ref = 'O-101';
