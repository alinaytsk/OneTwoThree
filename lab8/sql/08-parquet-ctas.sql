-- Way A, step 7: the deduplicated payments written once as Parquet, partitioned by day.
--
-- The same rows as the view, in a columnar format. A query that touches four columns now
-- reads four columns, not 1.2 GB of JSON text, and Athena bills what it reads.
--
-- dt must come last in the SELECT: Athena takes the partition columns from the end of the
-- column list, not by name.

CREATE TABLE payments_parquet
WITH (
  format = 'PARQUET',
  parquet_compression = 'SNAPPY',
  external_location = 's3://ucu-lab8-payments-896138901201/curated/payments/',
  partitioned_by = ARRAY['dt']
) AS
SELECT
  invoiceId,
  status,
  failureReason,
  amount,
  finalAmount,
  ccy,
  reference,
  created_at,
  modified_at,
  received_at,
  merchantId,
  merchantName,
  mcc,
  customerId,
  paymentMethod,
  device,
  dt
FROM payments;
