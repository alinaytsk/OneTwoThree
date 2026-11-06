-- Way A, step 2: one row per payment, holding its latest status.
--
-- Two different problems, in this order:
--
--   DISTINCT removes repeats - the same event delivered twice. Measured: 30 197 of
--   3 030 197 rows, and every one of them is byte-identical, so DISTINCT catches all.
--
--   row_number() then picks the last event of each payment. It does NOT remove repeats:
--   a repeated row is a separate row with the same modifiedDate, so the two tie, and
--   row_number() keeps one of them arbitrarily - which only looks right. Anything that
--   counts rows instead of picking one (a SUM over events, a COUNT of statuses) would be
--   1% too high. Order matters because the two steps answer different questions:
--   "is this the same event?" and "which event is the latest?".

CREATE OR REPLACE VIEW payments AS
WITH deduped AS (
  SELECT DISTINCT * FROM payment_events
),
ranked AS (
  SELECT
    *,
    row_number() OVER (
      PARTITION BY invoiceId
      -- the latest event time wins; on a tie, prefer a terminal status over an earlier one
      ORDER BY from_iso8601_timestamp(modifiedDate) DESC,
               CASE status WHEN 'success' THEN 3 WHEN 'failure' THEN 3
                           WHEN 'processing' THEN 2 ELSE 1 END DESC
    ) AS rn
  FROM deduped
)
SELECT
  invoiceId,
  status,
  failureReason,
  amount,
  finalAmount,
  ccy,
  reference,
  cast(from_iso8601_timestamp(createdDate) AS timestamp)  AS created_at,
  cast(from_iso8601_timestamp(modifiedDate) AS timestamp) AS modified_at,
  cast(from_iso8601_timestamp(receivedAt) AS timestamp)   AS received_at,
  merchantId,
  merchantName,
  mcc,
  customerId,
  paymentMethod,
  device,
  dt
FROM ranked
WHERE rn = 1;
