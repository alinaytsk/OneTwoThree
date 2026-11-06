-- The three numbers the lab asks for about scale, plus the one that decides how to
-- deduplicate: are the repeats byte-identical, or do they differ in receivedAt?
--
-- A repeat that differs only in receivedAt is not caught by SELECT DISTINCT, and it would
-- survive into the view. Counting both tells us which it is before we write the view.

SELECT
  count(*)                                   AS events,
  count(DISTINCT invoiceId)                  AS unique_payments,

  -- a repeat of the whole row, receivedAt included
  count(*) - count(DISTINCT
    ARRAY[invoiceId, status, modifiedDate, receivedAt,
          cast(finalAmount AS varchar), coalesce(failureReason, '')])
                                             AS exact_duplicates,

  -- the same event of the same payment, whatever receivedAt says
  count(*) - count(DISTINCT ARRAY[invoiceId, status, modifiedDate])
                                             AS logical_duplicates,

  count_if(date_diff('second',
      from_iso8601_timestamp(modifiedDate),
      from_iso8601_timestamp(receivedAt)) > 3600)        AS later_than_an_hour,
  round(100.0 * count_if(date_diff('second',
      from_iso8601_timestamp(modifiedDate),
      from_iso8601_timestamp(receivedAt)) > 3600) / count(*), 4) AS pct_later_than_an_hour,

  count_if(date_diff('second',
      from_iso8601_timestamp(modifiedDate),
      from_iso8601_timestamp(receivedAt)) > 60)          AS later_than_a_minute,
  round(100.0 * count_if(date_diff('second',
      from_iso8601_timestamp(modifiedDate),
      from_iso8601_timestamp(receivedAt)) > 60) / count(*), 4)   AS pct_later_than_a_minute
FROM payment_events;
