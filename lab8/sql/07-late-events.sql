-- Query 6: how late events were, over the raw events rather than the view.
--
-- Lateness is a property of a delivery, so it belongs to the event stream. The view keeps
-- one event per payment and would hide most of it.

SELECT
  count(*)                                                        AS events,
  count_if(delay_seconds > 60)                                    AS later_than_60s,
  round(100.0 * count_if(delay_seconds > 60) / count(*), 3)       AS pct_later_than_60s,
  count_if(delay_seconds > 3600)                                  AS later_than_an_hour,
  max(delay_seconds)                                              AS worst_delay_seconds,
  round(avg(delay_seconds), 2)                                    AS average_delay_seconds,
  approx_percentile(cast(delay_seconds AS double), 0.99)          AS p99_delay_seconds
FROM (
  SELECT date_diff('second',
           from_iso8601_timestamp(modifiedDate),
           from_iso8601_timestamp(receivedAt)) AS delay_seconds
  FROM payment_events
);
