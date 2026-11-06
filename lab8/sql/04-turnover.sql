-- Query 3: turnover by merchant and currency, successful payments only, in major units.
--
-- finalAmount, not amount: it is what was actually captured, and it is non-zero only on
-- success. Minor units -> major by dividing by 100, which holds for UAH, USD and EUR.

SELECT
  merchantId,
  merchantName,
  CASE ccy WHEN 980 THEN 'UAH' WHEN 840 THEN 'USD' WHEN 978 THEN 'EUR'
           ELSE cast(ccy AS varchar) END       AS currency,
  count(*)                                     AS payments,
  cast(sum(finalAmount) / 100.0 AS decimal(18, 2))  AS turnover,
  cast(avg(finalAmount) / 100.0 AS decimal(18, 2))  AS average_payment
FROM payments
WHERE status = 'success'
GROUP BY merchantId, merchantName, ccy
ORDER BY merchantId, currency;
