-- Part 4, the query to screenshot: the failure rate per payment method, computed over
-- the events that travelled through Kinesis and Firehose.
--
-- This is the batch half answering the same question the Lambda answered in real time,
-- which is the whole point of writing the raw events to S3: the stream gives an answer
-- in seconds and forgets, the lake gives the same answer later and keeps it.

SELECT
  paymentMethod,
  count(*)                                                  AS terminal_events,
  count_if(status = 'failure')                              AS failed,
  round(100.0 * count_if(status = 'failure') / count(*), 1) AS failure_rate_pct,
  min(modifiedDate)                                         AS first_event,
  max(modifiedDate)                                         AS last_event
FROM stream_events
WHERE status IN ('success', 'failure')
GROUP BY paymentMethod
ORDER BY failure_rate_pct DESC;
