# Part 1 — Uklon's data architecture: the three questions

## What happens if the real-time road falls behind by 10 minutes? And the batch road by a day?

They fail differently, and only one of them is an incident.

**The real-time road breaking is the product breaking.** Ten minutes is forever for a ride.
Surge pricing would be computed from where drivers were ten minutes ago, so a district that
emptied out would still look well supplied and the multiplier would stay at 1.0 while nobody
can get a car. Matching reads driver positions from Redis: a stale position sends a driver to
a passenger who is now three kilometres away, and the ETA shown to the passenger is a lie. The
push through SNS arrives after the passenger has already closed the app. Worse, these errors
are not symmetric - a surge that is too low loses money quietly, while an ETA that is too
optimistic produces cancelled rides and a one-star rating. The honest response is to degrade
rather than to serve stale numbers: freeze surge at its last confident value, widen the
matching radius, and stop promising an ETA.

**The batch road breaking is an inconvenience with a deadline.** Nobody rides a dashboard. A
day-old Glue job means yesterday's Parquet is missing, Athena queries return a short month and
Quick shows a hole. The analysts wait, the finance report is late, and the ETA model trains on
data that stops a day early - which changes nothing, because it is retrained on weeks of
history. The pipeline catches up by itself: the raw events are already in S3, so the job reruns
over the partition it missed. It becomes an incident only when it stops being one day: a week
of missed partitions means the backfill competes with the nightly run for the same capacity,
and if the raw files were never written - the Firehose broke, not the Glue job - then the data
is gone and no rerun brings it back.

The asymmetry is the reason the two roads exist. If one pipeline served both, every analytics
query would share a fate with surge pricing.

## Why does GPS not go through Lambda?

Because of what 580 million pings a day actually are: a constant 6 700 events per second from
hundreds of thousands of connections that are open all day and send 50 bytes at a time.

A Lambda invocation per ping is the wrong unit of work in three separate ways. **Price:** at
roughly $0.20 per million requests, 580 million invocations is about $116 a day in request
charges alone, before any compute time, and API Gateway in front of it would add far more.
**Connection cost:** every ping over HTTP pays for a TLS handshake or at best a kept-alive
connection that a serverless front door does not guarantee; MQTT opens one connection per
driver and keeps it, which is why phone batteries survive a shift. **Shape of the work:** a
ping is not a transaction. Losing one of them costs nothing, because another arrives in three
seconds, while Lambda gives retries, dead-letter queues and at-least-once delivery that nobody
needs here and everybody pays for.

IoT Core is built for exactly this shape: a persistent MQTT connection per device, priced per
million messages and per connection-minute rather than per request, with a rules engine that
forwards straight into Kinesis without a function in between. Lambda still appears in the
diagram, but where the unit of work fits it: once per file that Firehose writes, which is
thousands of pings per invocation.

The general rule is visible here: Lambda is priced per invocation, so it suits work whose
natural unit is one invocation - a file arriving, an order placed, an HTTP request worth
answering. A steady high-rate stream of tiny messages is the one shape it fits worst.

## Which parts would a small startup drop first, and what would it lose?

Roughly in this order, because each one costs real money or real attention and buys something
a small service does not need yet:

1. **SageMaker, and the ETA and demand models.** A distance-and-traffic formula gets within a
   few minutes. Lost: accuracy that matters at scale, where a systematically optimistic ETA
   costs cancellations - but at ten thousand rides a day nobody has the data to train on
   anyway.
2. **Flink.** Surge can be a scheduled query every minute over the last five minutes of events,
   or even a few lines in the matching service. Lost: windowing, exactly-once state and
   out-of-order handling, which is to say correctness under load - the thing that is fine
   until it is suddenly not.
3. **Glue and the nightly Parquet job.** Athena reads the raw JSON directly. Lost: speed and
   money, which is precisely what Part 2 measures - the same query reads 1.2 GB instead of
   6 MB, roughly two hundred times the cost. Harmless at one gigabyte a month, painful at a
   terabyte.
4. **Kinesis and Firehose.** The services write events to S3 themselves, or to a queue. Lost:
   the replayability that makes the diagram work at all - with a stream, a new consumer reads
   the same history from the beginning; without it, an event is delivered once and the next
   idea for a consumer has no data.
5. **DMS change data capture.** Analytics reads a replica of Aurora instead. Lost: the
   complete history of changes; a replica shows what a row holds now, not that it was
   cancelled and recreated twice in between.

What a startup should **not** drop: S3 as the raw landing zone, and the discipline of writing
every event there before anything processes it. It costs cents, it is the one piece that cannot
be reconstructed later, and every other box in the diagram can be rebuilt from it. The second
thing to keep is IoT Core, if there are devices - not for scale, but because the alternative
teaches the client apps a protocol that becomes impossible to change once drivers' phones are
running it.
