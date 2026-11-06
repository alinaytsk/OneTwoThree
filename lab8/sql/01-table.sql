-- Way A, step 1: the raw events, read straight out of S3.
--
-- Every field is a string in the JSON, except the four numbers. The dates stay strings
-- on purpose: the JSON SerDe will not parse "2026-10-01T08:15:22Z" into a timestamp, and
-- a failed cast turns the whole row into NULLs rather than an error. The queries parse
-- them with from_iso8601_timestamp, which fails loudly instead.
--
-- dt is not in the JSON. It is the partition, and it comes from the key:
-- payments/dt=2026-10-01/events.jsonl

CREATE EXTERNAL TABLE IF NOT EXISTS payments_raw.payment_events (
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
LOCATION 's3://ucu-lab8-payments-896138901201/payments/'
TBLPROPERTIES ('has_encrypted_data' = 'false');
