#!/usr/bin/env bash
# Part 4: the same payments, through a cloud pipeline.
#
#   producer -> Kinesis Data Stream -> Firehose -> S3 (raw/) -> Athena
#                     |
#                     +-> a Lambda that watches the failure rate -> SNS -> email
#
# Everything here is billed by the hour, so teardown.sh is the other half of this file.
set -euo pipefail
export AWS_REGION=us-east-1

BUCKET=ucu-lab8-payments-896138901201
STREAM=lab8-payments-stream
DELIVERY=lab8-payments-firehose
TOPIC=lab8-payment-alerts
FIREHOSE_ROLE=lab8-firehose-role
LAMBDA_ROLE=lab8-alerts-role
LAMBDA=lab8-failure-alerts
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

say() { printf '\n== %s\n' "$1"; }

say "Kinesis stream (1 shard: 1 MB/s in, enough for 60 events/s)"
if ! aws kinesis describe-stream-summary --stream-name "$STREAM" >/dev/null 2>&1; then
  aws kinesis create-stream --stream-name "$STREAM" --shard-count 1
  aws kinesis wait stream-exists --stream-name "$STREAM"
fi
STREAM_ARN=$(aws kinesis describe-stream-summary --stream-name "$STREAM" \
  --query StreamDescriptionSummary.StreamARN --output text)
echo "$STREAM_ARN"

say "SNS topic for the alerts"
TOPIC_ARN=$(aws sns create-topic --name "$TOPIC" --query TopicArn --output text)
echo "$TOPIC_ARN"

say "Firehose role"
if ! aws iam get-role --role-name "$FIREHOSE_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$FIREHOSE_ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"firehose.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam put-role-policy --role-name "$FIREHOSE_ROLE" --policy-name write-s3-read-kinesis \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"s3:AbortMultipartUpload\",\"s3:GetBucketLocation\",\"s3:GetObject\",\"s3:ListBucket\",\"s3:ListBucketMultipartUploads\",\"s3:PutObject\"],\"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]},
      {\"Effect\":\"Allow\",\"Action\":[\"kinesis:DescribeStream\",\"kinesis:GetShardIterator\",\"kinesis:GetRecords\",\"kinesis:ListShards\"],\"Resource\":\"${STREAM_ARN}\"},
      {\"Effect\":\"Allow\",\"Action\":[\"logs:PutLogEvents\",\"logs:CreateLogStream\",\"logs:CreateLogGroup\"],\"Resource\":\"*\"}]}"
  sleep 15
fi
FIREHOSE_ROLE_ARN=$(aws iam get-role --role-name "$FIREHOSE_ROLE" --query Role.Arn --output text)

say "Firehose: Kinesis -> S3, batched"
if ! aws firehose describe-delivery-stream --delivery-stream-name "$DELIVERY" >/dev/null 2>&1; then
  aws firehose create-delivery-stream \
    --delivery-stream-name "$DELIVERY" \
    --delivery-stream-type KinesisStreamAsSource \
    --kinesis-stream-source-configuration "KinesisStreamARN=${STREAM_ARN},RoleARN=${FIREHOSE_ROLE_ARN}" \
    --extended-s3-destination-configuration "{
      \"RoleARN\": \"${FIREHOSE_ROLE_ARN}\",
      \"BucketARN\": \"arn:aws:s3:::${BUCKET}\",
      \"Prefix\": \"stream/raw/dt=!{timestamp:yyyy-MM-dd}/\",
      \"ErrorOutputPrefix\": \"stream/errors/\",
      \"BufferingHints\": {\"SizeInMBs\": 5, \"IntervalInSeconds\": 60},
      \"CompressionFormat\": \"UNCOMPRESSED\"
    }" >/dev/null
  echo "created, waiting for it to become ACTIVE"
  while [ "$(aws firehose describe-delivery-stream --delivery-stream-name "$DELIVERY" \
      --query DeliveryStreamDescription.DeliveryStreamStatus --output text)" != "ACTIVE" ]; do
    sleep 10
  done
fi
echo "firehose ACTIVE"

say "Lambda role for the alert"
if ! aws iam get-role --role-name "$LAMBDA_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$LAMBDA_ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$LAMBDA_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaKinesisExecutionRole
  aws iam put-role-policy --role-name "$LAMBDA_ROLE" --policy-name publish-alerts \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sns:Publish\",\"Resource\":\"${TOPIC_ARN}\"}]}"
  sleep 15
fi
LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE" --query Role.Arn --output text)

say "Lambda that raises the alert"
# python's zipfile rather than zip(1), which is not installed everywhere
( cd "$(dirname "$0")" && rm -f alerts.zip && python3 -c \
  "import zipfile; zipfile.ZipFile('alerts.zip','w',zipfile.ZIP_DEFLATED).write('alerts.py')" )
ZIP="$(dirname "$0")/alerts.zip"
if aws lambda get-function --function-name "$LAMBDA" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$LAMBDA" --zip-file "fileb://${ZIP}" >/dev/null
else
  aws lambda create-function --function-name "$LAMBDA" \
    --runtime python3.12 --handler alerts.handler --role "$LAMBDA_ROLE_ARN" \
    --zip-file "fileb://${ZIP}" --timeout 30 --memory-size 256 \
    --environment "Variables={ALERT_TOPIC_ARN=${TOPIC_ARN},FAILURE_THRESHOLD=0.10}" >/dev/null
  aws lambda wait function-active --function-name "$LAMBDA"
fi

if ! aws lambda list-event-source-mappings --function-name "$LAMBDA" \
     --query 'EventSourceMappings[?contains(EventSourceArn, `'"$STREAM"'`)].UUID' --output text | grep -q .; then
  aws lambda create-event-source-mapping --function-name "$LAMBDA" \
    --event-source-arn "$STREAM_ARN" --starting-position LATEST \
    --batch-size 500 --maximum-batching-window-in-seconds 30 >/dev/null
fi
echo "lambda wired to the stream"

say "done"
echo "stream:   $STREAM"
echo "firehose: $DELIVERY -> s3://${BUCKET}/stream/raw/"
echo "alerts:   $TOPIC_ARN"
echo
echo "Subscribe an address to the alerts with:"
echo "  aws sns subscribe --topic-arn ${TOPIC_ARN} --protocol email --notification-endpoint YOU@EXAMPLE.COM"
