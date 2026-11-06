-- Query 5: payments per hour of the day.
--
-- By created_at: when the payment started, which is the hour that carries the load.

SELECT
  hour(created_at)                         AS hour_of_day,
  count(*)                                 AS payments,
  count_if(status = 'success')             AS succeeded,
  cast(sum(finalAmount) / 100.0 AS decimal(18, 2)) AS turnover_all_currencies
FROM payments
GROUP BY hour(created_at)
ORDER BY hour_of_day;
