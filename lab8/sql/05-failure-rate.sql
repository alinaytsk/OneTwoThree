-- Query 4: the share of failed payments per payment method and device, highest first.
--
-- One row per payment, so this is a share of payments, not of events. Payments still in
-- flight (created, processing) are counted in the denominator: they are attempts that have
-- not failed yet. The share of each terminal status is shown so the three add up visibly.

SELECT
  paymentMethod,
  device,
  count(*)                                              AS payments,
  count_if(status = 'failure')                          AS failed,
  round(100.0 * count_if(status = 'failure') / count(*), 2) AS failure_rate_pct,
  round(100.0 * count_if(status = 'success') / count(*), 2) AS success_rate_pct,
  round(100.0 * count_if(status IN ('created', 'processing')) / count(*), 2) AS in_flight_pct
FROM payments
GROUP BY paymentMethod, device
ORDER BY failure_rate_pct DESC;
