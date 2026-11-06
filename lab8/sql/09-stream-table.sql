-- Part 4: the events that arrived through Kinesis and were written by Firehose.
--
-- The same JSON, in the same shape, in a different prefix - which is the point. Nothing
-- downstream of S3 knows or cares that these rows came through a stream rather than a
-- nightly copy. dt here is Firehose's delivery date, not the payment's day: Firehose
-- names the prefix from the wall clock when it writes the batch.

CREATE EXTERNAL TABLE IF NOT EXISTS payments_raw.stream_events (
  invoiceId     string,
  status        string,
  failureReason string,
  amount        bigint,
  finalAmount   bigint,
  ccy           int,
  reference     string,
  createdDate   string,
  modifiedDate  string,
  receivedAt    string,
  merchantId    string,
  merchantName  string,
  mcc           int,
  customerId    string,
  paymentMethod string,
  device        string
)
PARTITIONED BY (dt string)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES ('ignore.malformed.json' = 'true')
LOCATION 's3://ucu-lab8-payments-896138901201/stream/raw/';
